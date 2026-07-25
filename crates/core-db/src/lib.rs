use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    str::FromStr,
    time::Duration,
};

use anyhow::{bail, Context, Result};
use chrono::{DateTime, Utc};
use protocol::{
    AlbumDetail, AlbumSummary, ArtistAsset, ArtistDetail, ArtistProfile, ArtistSummary,
    ArtistVisual, ArtistVisualRegion, AudioMasterSummary, CatalogRecordingSummary,
    CatalogWorkSummary, ClientLibraryFileBinding, ClientLibraryManifestRequest,
    ClientLibraryManifestResult, ClientLibraryRootStatus, ClientMutationBatchRequest,
    ClientMutationBatchResult, ClientSyncChange, ClientTrackManifest, CreateDistributionRequest,
    DistributionContentSource, DistributionJobSummary, DistributionSourceTaskAssignment,
    DistributionTaskAssignment, DistributionTaskProgress, DistributionTranscodeTask, LibraryCounts,
    LibraryRoot, LyricPayload, MediaReplicaSummary, MediaVariantSummary, NewPlaylist,
    PlaybackEvent, PlaybackMode, PlaybackQueue, PlaybackQueueItem, PlaybackSession, PlaybackStats,
    PlaylistDetail, PlaylistKind, PlaylistSummary, PlaylistTrackMutation, RecordingLinkCandidate,
    RelatedReleaseTrackSummary, ReleaseEditionSummary, ReplacePlaybackQueue, ScanProblem,
    TrackDetail, TrackEditSnapshot, TrackFavoriteUpdate, TrackMediaProfile, TrackMetadataField,
    TrackMetadataUpdate, TrackPlaybackStat, TrackSummary, UpdateArtistAsset, UpdateArtistProfile,
    UpdateArtistVisual, UpdatePlaylist, ZoneVolume,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha384};
use sqlx::{
    migrate::Migrator,
    sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous},
    QueryBuilder, Row, Sqlite, SqlitePool,
};
use tracing::warn;
use uuid::Uuid;

pub type DbPool = SqlitePool;

static MIGRATOR: Migrator = sqlx::migrate!("./src/migrations");

pub async fn connect(database_file: &Path) -> Result<DbPool> {
    if let Some(parent) = database_file.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .with_context(|| format!("failed to create database directory {}", parent.display()))?;
    }

    let options = SqliteConnectOptions::from_str(&database_file.to_string_lossy())?
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Normal)
        .foreign_keys(true)
        .busy_timeout(Duration::from_secs(30));

    let pool = SqlitePoolOptions::new()
        .max_connections(8)
        .connect_with(options)
        .await
        .with_context(|| format!("failed to open database {}", database_file.display()))?;

    Ok(pool)
}

pub async fn migrate(pool: &DbPool) -> Result<()> {
    repair_line_ending_migration_checksums(pool).await?;
    MIGRATOR
        .run(pool)
        .await
        .context("failed to run database migrations")?;
    Ok(())
}

pub async fn sync_server_id(pool: &DbPool) -> Result<String> {
    let existing: Option<String> =
        sqlx::query_scalar("SELECT server_id FROM core_sync_state WHERE id = 1")
            .fetch_optional(pool)
            .await?
            .flatten();
    if let Some(server_id) = existing.filter(|value| !value.trim().is_empty()) {
        return Ok(server_id);
    }

    let server_id = Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT INTO core_sync_state (id, server_id, created_at, updated_at)
        VALUES (1, ?1, ?2, ?2)
        ON CONFLICT(id) DO UPDATE SET
            server_id = COALESCE(NULLIF(core_sync_state.server_id, ''), excluded.server_id),
            updated_at = excluded.updated_at
        "#,
    )
    .bind(&server_id)
    .bind(&now)
    .execute(pool)
    .await?;
    Ok(
        sqlx::query_scalar("SELECT server_id FROM core_sync_state WHERE id = 1")
            .fetch_one(pool)
            .await?,
    )
}

pub async fn sync_cursor(pool: &DbPool) -> Result<u64> {
    let cursor: i64 =
        sqlx::query_scalar("SELECT COALESCE(MAX(cursor), 0) FROM client_sync_changes")
            .fetch_one(pool)
            .await?;
    Ok(u64::try_from(cursor.max(0))?)
}

pub async fn append_sync_change(pool: &DbPool, scope: &str, reason: &str) -> Result<u64> {
    let result = sqlx::query(
        r#"
        INSERT INTO client_sync_changes (scope, reason, created_at)
        VALUES (?1, ?2, ?3)
        "#,
    )
    .bind(scope)
    .bind(reason)
    .bind(Utc::now().to_rfc3339())
    .execute(pool)
    .await?;
    let cursor = result.last_insert_rowid();
    if cursor % 1_000 == 0 {
        sqlx::query("DELETE FROM client_sync_changes WHERE cursor < ?1")
            .bind(cursor.saturating_sub(50_000))
            .execute(pool)
            .await?;
    }
    Ok(u64::try_from(cursor)?)
}

pub async fn client_sync_changes(
    pool: &DbPool,
    after: u64,
    limit: u32,
) -> Result<Vec<ClientSyncChange>> {
    let rows = sqlx::query(
        r#"
        SELECT cursor, scope, reason, created_at
        FROM client_sync_changes
        WHERE cursor > ?1
        ORDER BY cursor
        LIMIT ?2
        "#,
    )
    .bind(i64::try_from(after)?)
    .bind(i64::from(limit.clamp(1, 2_000)))
    .fetch_all(pool)
    .await?;
    rows.into_iter()
        .map(|row| {
            Ok(ClientSyncChange {
                cursor: u64::try_from(row.try_get::<i64, _>("cursor")?)?,
                scope: row.try_get("scope")?,
                reason: row.try_get("reason")?,
                created_at: parse_datetime(row.try_get::<String, _>("created_at")?)?,
            })
        })
        .collect()
}

async fn repair_line_ending_migration_checksums(pool: &DbPool) -> Result<()> {
    let migrations_table_exists: Option<i64> = sqlx::query_scalar(
        r#"
        SELECT 1
        FROM sqlite_master
        WHERE type = 'table' AND name = '_sqlx_migrations'
        "#,
    )
    .fetch_optional(pool)
    .await?;
    if migrations_table_exists.is_none() {
        return Ok(());
    }

    for migration in MIGRATOR.iter() {
        let stored_checksum: Option<Vec<u8>> = sqlx::query_scalar(
            r#"
            SELECT checksum
            FROM _sqlx_migrations
            WHERE version = ?1 AND success = 1
            "#,
        )
        .bind(migration.version)
        .fetch_optional(pool)
        .await?;
        let Some(stored_checksum) = stored_checksum else {
            continue;
        };
        if stored_checksum.as_slice() == migration.checksum.as_ref() {
            continue;
        }

        let line_ending_checksums = migration_line_ending_checksums(&migration.sql);
        if !line_ending_checksums
            .iter()
            .any(|checksum| checksum.as_slice() == stored_checksum)
        {
            continue;
        }

        let result = sqlx::query(
            r#"
            UPDATE _sqlx_migrations
            SET checksum = ?1
            WHERE version = ?2 AND success = 1 AND checksum = ?3
            "#,
        )
        .bind(migration.checksum.as_ref())
        .bind(migration.version)
        .bind(&stored_checksum)
        .execute(pool)
        .await?;
        if result.rows_affected() == 1 {
            warn!(
                version = migration.version,
                "repaired a migration checksum changed only by line endings"
            );
        }
    }
    Ok(())
}

fn migration_line_ending_checksums(sql: &str) -> [Vec<u8>; 2] {
    let lf = sql.replace("\r\n", "\n").replace('\r', "\n");
    let crlf = lf.replace('\n', "\r\n");
    [
        Sha384::digest(lf.as_bytes()).to_vec(),
        Sha384::digest(crlf.as_bytes()).to_vec(),
    ]
}

pub async fn sync_configured_roots(pool: &DbPool, roots: &[PathBuf]) -> Result<()> {
    for root in roots {
        add_library_root(pool, root).await?;
    }
    Ok(())
}

pub async fn add_library_root(pool: &DbPool, path: &Path) -> Result<LibraryRoot> {
    let now = Utc::now().to_rfc3339();
    let normalized = normalize_path(path);
    sqlx::query(
        r#"
        INSERT INTO library_roots (path, enabled, root_kind, created_at, updated_at)
        VALUES (?1, 1, 'core', ?2, ?2)
        ON CONFLICT(path) DO UPDATE SET
            enabled = 1,
            root_kind = 'core',
            updated_at = excluded.updated_at
        "#,
    )
    .bind(&normalized)
    .bind(&now)
    .execute(pool)
    .await?;

    get_library_root_by_path(pool, &normalized).await
}

pub async fn remove_library_root(pool: &DbPool, id: i64) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    sqlx::query("UPDATE library_roots SET enabled = 0, updated_at = ?1 WHERE id = ?2")
        .bind(now)
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn list_library_roots(pool: &DbPool) -> Result<Vec<LibraryRoot>> {
    let rows = sqlx::query(
        r#"
        SELECT id, path, enabled, created_at, updated_at
        FROM library_roots
        WHERE root_kind = 'core'
        ORDER BY path
        "#,
    )
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_library_root).collect()
}

pub async fn enabled_library_roots(pool: &DbPool) -> Result<Vec<LibraryRoot>> {
    let rows = sqlx::query(
        r#"
        SELECT id, path, enabled, created_at, updated_at
        FROM library_roots
        WHERE enabled = 1 AND root_kind = 'core'
        ORDER BY path
        "#,
    )
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_library_root).collect()
}

async fn get_library_root_by_path(pool: &DbPool, path: &str) -> Result<LibraryRoot> {
    let row = sqlx::query(
        r#"
        SELECT id, path, enabled, created_at, updated_at
        FROM library_roots
        WHERE path = ?1 AND root_kind = 'core'
        "#,
    )
    .bind(path)
    .fetch_one(pool)
    .await?;
    row_to_library_root(row)
}

pub async fn library_counts(pool: &DbPool) -> Result<LibraryCounts> {
    Ok(LibraryCounts {
        library_roots: count(pool, "library_roots", "enabled = 1 AND root_kind = 'core'").await?,
        files: count(pool, "files", "deleted_at IS NULL").await?,
        tracks: count(pool, "tracks", "1 = 1").await?,
        albums: count(pool, "albums", "1 = 1").await?,
        artists: count(pool, "artists", "1 = 1").await?,
        scan_problems: count(pool, "files", "scan_status != 'ok' AND deleted_at IS NULL").await?,
    })
}

async fn count(pool: &DbPool, table: &str, where_clause: &str) -> Result<i64> {
    let sql = format!("SELECT COUNT(*) AS count FROM {table} WHERE {where_clause}");
    let row = sqlx::query(&sql).fetch_one(pool).await?;
    Ok(row.try_get("count")?)
}

#[derive(Debug, Clone)]
pub struct FileIngest {
    pub library_root_id: i64,
    pub path: String,
    pub relative_path: String,
    pub extension: String,
    pub size_bytes: i64,
    pub modified_at: String,
    pub quick_hash: Option<String>,
    pub scan_status: String,
    pub scan_message: Option<String>,
    pub codec: Option<String>,
    pub sample_rate: Option<i64>,
    pub channels: Option<i64>,
    pub duration_ms: Option<i64>,
    pub bitrate: Option<i64>,
    pub bit_depth: Option<i64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct TrackIngest {
    pub title: String,
    pub sort_title: Option<String>,
    pub subtitle: Option<String>,
    pub album: Option<String>,
    pub track_artists: Vec<String>,
    pub album_artists: Vec<String>,
    pub composers: Vec<String>,
    pub lyricists: Vec<String>,
    pub genres: Vec<String>,
    pub disc_number: Option<i64>,
    pub disc_total: Option<i64>,
    pub track_number: Option<i64>,
    pub track_total: Option<i64>,
    pub duration_ms: Option<i64>,
    pub date: Option<String>,
    pub year: Option<i64>,
    pub bpm: Option<i64>,
    pub comment: Option<String>,
    pub lyrics: Option<String>,
    pub lyrics_kind: Option<String>,
    pub tag_rating: Option<i64>,
    pub tag_rating_scale: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct PlaybackEventIngest {
    pub zone_id: String,
    pub event_type: String,
    pub track_id: Option<i64>,
    pub track_title: Option<String>,
    pub position_ms: Option<u64>,
    pub related_zone_id: Option<String>,
    pub reason: Option<String>,
}

pub async fn upsert_scanned_file(
    pool: &DbPool,
    file: &FileIngest,
    track: Option<&TrackIngest>,
) -> Result<i64> {
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT INTO files (
            library_root_id, path, relative_path, extension, size_bytes, modified_at,
            quick_hash, scan_status, scan_message, codec, sample_rate, channels,
            duration_ms, bitrate, bit_depth, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?16)
        ON CONFLICT(path) DO UPDATE SET
            library_root_id = excluded.library_root_id,
            relative_path = excluded.relative_path,
            extension = excluded.extension,
            size_bytes = excluded.size_bytes,
            modified_at = excluded.modified_at,
            quick_hash = excluded.quick_hash,
            scan_status = excluded.scan_status,
            scan_message = excluded.scan_message,
            codec = excluded.codec,
            sample_rate = excluded.sample_rate,
            channels = excluded.channels,
            duration_ms = excluded.duration_ms,
            bitrate = excluded.bitrate,
            bit_depth = excluded.bit_depth,
            updated_at = excluded.updated_at,
            deleted_at = NULL
        "#,
    )
    .bind(file.library_root_id)
    .bind(&file.path)
    .bind(&file.relative_path)
    .bind(&file.extension)
    .bind(file.size_bytes)
    .bind(&file.modified_at)
    .bind(&file.quick_hash)
    .bind(&file.scan_status)
    .bind(&file.scan_message)
    .bind(&file.codec)
    .bind(file.sample_rate)
    .bind(file.channels)
    .bind(file.duration_ms)
    .bind(file.bitrate)
    .bind(file.bit_depth)
    .bind(&now)
    .execute(pool)
    .await?;

    let file_id: i64 = sqlx::query("SELECT id FROM files WHERE path = ?1")
        .bind(&file.path)
        .fetch_one(pool)
        .await?
        .try_get("id")?;

    if let Some(track) = track {
        save_track_metadata_source(pool, file_id, track).await?;
        let mut effective = track.clone();
        if let Some(track_id) = track_id_for_file(pool, file_id).await? {
            apply_metadata_overrides(
                &mut effective,
                &load_track_metadata_overrides(pool, track_id).await?,
            )?;
        }
        let track_id = upsert_track(pool, file_id, file.library_root_id, &effective).await?;
        ensure_track_media_graph(pool, track_id, file_id, file, &effective).await?;
    } else {
        sqlx::query("DELETE FROM tracks WHERE file_id = ?1")
            .bind(file_id)
            .execute(pool)
            .await?;
    }

    Ok(file_id)
}

pub async fn upsert_client_library_manifest(
    pool: &DbPool,
    manifest: &ClientLibraryManifestRequest,
) -> Result<ClientLibraryManifestResult> {
    let device_id = manifest.device_id.trim();
    let device_name = manifest.device_name.trim();
    let root_external_id = manifest.root.external_id.trim();
    let root_display_name = manifest.root.display_name.trim();
    let scan_id = manifest.scan_id.trim();
    if device_id.is_empty() || device_id.len() > 200 {
        bail!("device_id must contain between 1 and 200 characters");
    }
    if device_name.is_empty() || device_name.len() > 300 {
        bail!("device_name must contain between 1 and 300 characters");
    }
    if root_external_id.is_empty() || root_external_id.len() > 200 {
        bail!("root.external_id must contain between 1 and 200 characters");
    }
    if root_display_name.is_empty() || root_display_name.len() > 500 {
        bail!("root.display_name must contain between 1 and 500 characters");
    }
    if scan_id.is_empty() || scan_id.len() > 200 {
        bail!("scan_id must contain between 1 and 200 characters");
    }
    if manifest.files.len() > 1_000 {
        bail!("a client library manifest batch cannot exceed 1000 files");
    }

    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT INTO devices (
            id, name, platform, token_hash, created_at, last_seen_at
        )
        VALUES (?1, ?2, ?3, 'client-library-manifest', ?4, ?4)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            platform = COALESCE(excluded.platform, devices.platform),
            last_seen_at = excluded.last_seen_at
        "#,
    )
    .bind(device_id)
    .bind(device_name)
    .bind(&manifest.platform)
    .bind(&now)
    .execute(pool)
    .await?;

    let root_path = format!(
        "intmusic-client://{}/{}",
        stable_shadow_segment(device_id),
        stable_shadow_segment(root_external_id)
    );
    sqlx::query(
        r#"
        INSERT INTO library_roots (
            path, enabled, root_kind, owner_device_id, external_id,
            display_name, path_hint, last_seen_at, created_at, updated_at
        )
        VALUES (?1, 1, 'client', ?2, ?3, ?4, ?5, ?6, ?6, ?6)
        ON CONFLICT(root_kind, owner_device_id, external_id)
        DO UPDATE SET
            enabled = 1,
            display_name = excluded.display_name,
            path_hint = excluded.path_hint,
            last_seen_at = excluded.last_seen_at,
            updated_at = excluded.updated_at
        "#,
    )
    .bind(&root_path)
    .bind(device_id)
    .bind(root_external_id)
    .bind(root_display_name)
    .bind(manifest.root.path_hint.as_deref().map(str::trim))
    .bind(&now)
    .execute(pool)
    .await?;
    let root_id: i64 = sqlx::query_scalar(
        r#"
        SELECT id
        FROM library_roots
        WHERE root_kind = 'client' AND owner_device_id = ?1 AND external_id = ?2
        "#,
    )
    .bind(device_id)
    .bind(root_external_id)
    .fetch_one(pool)
    .await?;

    sqlx::query(
        r#"
        INSERT INTO client_library_sync_state (
            device_id, root_external_id, scan_id, started_at,
            completed_at, accepted_files, missing_files
        )
        VALUES (?1, ?2, ?3, ?4, NULL, 0, 0)
        ON CONFLICT(device_id, root_external_id) DO UPDATE SET
            scan_id = excluded.scan_id,
            started_at = CASE
                WHEN client_library_sync_state.scan_id = excluded.scan_id
                THEN client_library_sync_state.started_at
                ELSE excluded.started_at
            END,
            completed_at = CASE
                WHEN client_library_sync_state.scan_id = excluded.scan_id
                THEN client_library_sync_state.completed_at
                ELSE NULL
            END,
            accepted_files = CASE
                WHEN client_library_sync_state.scan_id = excluded.scan_id
                THEN client_library_sync_state.accepted_files
                ELSE 0
            END,
            missing_files = CASE
                WHEN client_library_sync_state.scan_id = excluded.scan_id
                THEN client_library_sync_state.missing_files
                ELSE 0
            END
        "#,
    )
    .bind(device_id)
    .bind(root_external_id)
    .bind(scan_id)
    .bind(&now)
    .execute(pool)
    .await?;

    let mut accepted_files = 0_i64;
    let mut bindings = Vec::with_capacity(manifest.files.len());
    for item in &manifest.files {
        let client_file_id = item.external_id.trim();
        let relative_path = item.relative_path.trim().replace('\\', "/");
        if client_file_id.is_empty() || client_file_id.len() > 1_000 {
            bail!("file external_id must contain between 1 and 1000 characters");
        }
        if relative_path.is_empty() || relative_path.len() > 4_096 {
            bail!("file relative_path must contain between 1 and 4096 characters");
        }
        let extension = item
            .extension
            .trim()
            .trim_start_matches('.')
            .to_ascii_lowercase();
        if extension.is_empty() || extension.len() > 32 {
            bail!("file extension must contain between 1 and 32 characters");
        }
        if item.size_bytes < 0 {
            bail!("file size_bytes cannot be negative");
        }
        let shadow_path = format!(
            "{}/{}",
            root_path.trim_end_matches('/'),
            stable_shadow_segment(client_file_id)
        );
        let existing_file_id: Option<i64> =
            sqlx::query_scalar("SELECT id FROM files WHERE path = ?1")
                .bind(&shadow_path)
                .fetch_optional(pool)
                .await?;
        let existing_track_id: Option<i64> = if let Some(file_id) = existing_file_id {
            track_id_for_file(pool, file_id).await?
        } else {
            None
        };
        let matching_variant_id: Option<i64> = if existing_track_id.is_none() {
            if let Some(content_hash) = item
                .content_hash
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                sqlx::query_scalar(
                    r#"
                    SELECT variant.id
                    FROM media_variants variant
                    JOIN media_replicas replica ON replica.media_variant_id = variant.id
                    JOIN files existing_file ON existing_file.id = replica.file_id
                    WHERE variant.content_hash = ?1
                      AND existing_file.size_bytes = ?2
                      AND existing_file.deleted_at IS NULL
                    ORDER BY replica.is_primary DESC, variant.id
                    LIMIT 1
                    "#,
                )
                .bind(content_hash)
                .bind(item.size_bytes)
                .fetch_optional(pool)
                .await?
            } else if let Some(quick_hash) = item
                .quick_hash
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                sqlx::query_scalar(
                    r#"
                    SELECT variant.id
                    FROM media_variants variant
                    JOIN media_replicas replica ON replica.media_variant_id = variant.id
                    JOIN files existing_file ON existing_file.id = replica.file_id
                    WHERE variant.quick_hash = ?1
                      AND existing_file.size_bytes = ?2
                      AND existing_file.deleted_at IS NULL
                    ORDER BY replica.is_primary DESC, variant.id
                    LIMIT 1
                    "#,
                )
                .bind(quick_hash)
                .bind(item.size_bytes)
                .fetch_optional(pool)
                .await?
            } else {
                None
            }
        } else {
            None
        };
        let metadata = client_track_manifest_to_ingest(&item.metadata, &relative_path);
        let file = FileIngest {
            library_root_id: root_id,
            path: shadow_path,
            relative_path,
            extension,
            size_bytes: item.size_bytes,
            modified_at: item.modified_at.to_rfc3339(),
            quick_hash: item.quick_hash.clone(),
            scan_status: "ok".to_string(),
            scan_message: None,
            codec: item.codec.clone(),
            sample_rate: item.sample_rate,
            channels: item.channels,
            duration_ms: item.duration_ms,
            bitrate: item.bitrate,
            bit_depth: item.bit_depth,
        };
        let creates_catalog_track = existing_track_id.is_some() || matching_variant_id.is_none();
        let file_id =
            upsert_scanned_file(pool, &file, creates_catalog_track.then_some(&metadata)).await?;
        sqlx::query(
            r#"
            UPDATE files
            SET client_file_id = ?1,
                content_hash = ?2,
                last_seen_scan_id = ?3,
                availability_state = 'ready',
                deleted_at = NULL,
                updated_at = ?4
            WHERE id = ?5
            "#,
        )
        .bind(client_file_id)
        .bind(&item.content_hash)
        .bind(scan_id)
        .bind(&now)
        .bind(file_id)
        .execute(pool)
        .await?;
        sqlx::query(
            r#"
            UPDATE media_variants
            SET content_hash = ?1, updated_at = ?2
            WHERE id = (
                SELECT media_variant_id
                FROM media_replicas
                WHERE file_id = ?3
            )
            "#,
        )
        .bind(&item.content_hash)
        .bind(&now)
        .bind(file_id)
        .execute(pool)
        .await?;
        if let Some(media_variant_id) = matching_variant_id {
            sqlx::query(
                r#"
                INSERT INTO media_replicas (
                    media_variant_id, file_id, device_id, library_root_id,
                    source_kind, availability_state, is_primary,
                    last_verified_at, created_at, updated_at
                )
                VALUES (?1, ?2, ?3, ?4, 'client', 'ready', 0, ?5, ?5, ?5)
                ON CONFLICT(file_id) DO UPDATE SET
                    media_variant_id = excluded.media_variant_id,
                    device_id = excluded.device_id,
                    library_root_id = excluded.library_root_id,
                    source_kind = excluded.source_kind,
                    availability_state = excluded.availability_state,
                    last_verified_at = excluded.last_verified_at,
                    updated_at = excluded.updated_at
                "#,
            )
            .bind(media_variant_id)
            .bind(file_id)
            .bind(device_id)
            .bind(root_id)
            .bind(&now)
            .execute(pool)
            .await?;
        } else {
            sqlx::query(
                r#"
                UPDATE media_replicas
                SET device_id = ?1,
                    library_root_id = ?2,
                    source_kind = 'client',
                    availability_state = 'ready',
                    last_verified_at = ?3,
                    updated_at = ?3
                WHERE file_id = ?4
                "#,
            )
            .bind(device_id)
            .bind(root_id)
            .bind(&now)
            .bind(file_id)
            .execute(pool)
            .await?;
        }
        let binding_row = sqlx::query(
            r#"
            SELECT replica.media_variant_id, MIN(links.track_id) AS track_id
            FROM media_replicas replica
            JOIN release_track_media_variants relation
              ON relation.media_variant_id = replica.media_variant_id
            JOIN legacy_track_catalog_links links
              ON links.release_track_id = relation.release_track_id
            WHERE replica.file_id = ?1
            GROUP BY replica.media_variant_id
            "#,
        )
        .bind(file_id)
        .fetch_one(pool)
        .await?;
        bindings.push(ClientLibraryFileBinding {
            external_id: client_file_id.to_string(),
            track_id: binding_row.try_get("track_id")?,
            media_variant_id: binding_row.try_get("media_variant_id")?,
        });
        accepted_files += 1;
    }

    sqlx::query(
        r#"
        UPDATE client_library_sync_state
        SET accepted_files = accepted_files + ?1
        WHERE device_id = ?2 AND root_external_id = ?3 AND scan_id = ?4
        "#,
    )
    .bind(accepted_files)
    .bind(device_id)
    .bind(root_external_id)
    .bind(scan_id)
    .execute(pool)
    .await?;

    let mut missing_files = 0_i64;
    if manifest.complete {
        let result = sqlx::query(
            r#"
            UPDATE files
            SET availability_state = 'missing',
                deleted_at = COALESCE(deleted_at, ?1),
                updated_at = ?1
            WHERE library_root_id = ?2
              AND client_file_id IS NOT NULL
              AND COALESCE(last_seen_scan_id, '') <> ?3
              AND deleted_at IS NULL
            "#,
        )
        .bind(&now)
        .bind(root_id)
        .bind(scan_id)
        .execute(pool)
        .await?;
        missing_files = i64::try_from(result.rows_affected()).unwrap_or(i64::MAX);
        sqlx::query(
            r#"
            UPDATE media_replicas
            SET availability_state = 'missing', updated_at = ?1
            WHERE library_root_id = ?2
              AND file_id IN (
                  SELECT id FROM files
                  WHERE library_root_id = ?2
                    AND COALESCE(last_seen_scan_id, '') <> ?3
              )
            "#,
        )
        .bind(&now)
        .bind(root_id)
        .bind(scan_id)
        .execute(pool)
        .await?;
        sqlx::query(
            r#"
            UPDATE client_library_sync_state
            SET completed_at = ?1, missing_files = ?2
            WHERE device_id = ?3 AND root_external_id = ?4 AND scan_id = ?5
            "#,
        )
        .bind(&now)
        .bind(missing_files)
        .bind(device_id)
        .bind(root_external_id)
        .bind(scan_id)
        .execute(pool)
        .await?;
    }

    Ok(ClientLibraryManifestResult {
        root_id,
        accepted_files,
        missing_files,
        complete: manifest.complete,
        bindings,
    })
}

pub async fn remove_client_library_root(
    pool: &DbPool,
    device_id: &str,
    root_external_id: &str,
) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    let root_id: Option<i64> = sqlx::query_scalar(
        r#"
        SELECT id
        FROM library_roots
        WHERE root_kind = 'client' AND owner_device_id = ?1 AND external_id = ?2
        "#,
    )
    .bind(device_id)
    .bind(root_external_id)
    .fetch_optional(pool)
    .await?;
    let Some(root_id) = root_id else {
        return Ok(());
    };
    sqlx::query("UPDATE library_roots SET enabled = 0, updated_at = ?1 WHERE id = ?2")
        .bind(&now)
        .bind(root_id)
        .execute(pool)
        .await?;
    sqlx::query(
        r#"
        UPDATE files
        SET availability_state = 'missing',
            deleted_at = COALESCE(deleted_at, ?1),
            updated_at = ?1
        WHERE library_root_id = ?2
        "#,
    )
    .bind(&now)
    .bind(root_id)
    .execute(pool)
    .await?;
    sqlx::query(
        r#"
        UPDATE media_replicas
        SET availability_state = 'missing', updated_at = ?1
        WHERE library_root_id = ?2
        "#,
    )
    .bind(&now)
    .bind(root_id)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn list_client_library_roots(pool: &DbPool) -> Result<Vec<ClientLibraryRootStatus>> {
    let rows = sqlx::query(
        r#"
        SELECT
            root.id AS root_id,
            root.external_id,
            COALESCE(NULLIF(root.display_name, ''), root.external_id) AS display_name,
            root.owner_device_id AS device_id,
            device.name AS device_name,
            device.platform,
            root.path_hint,
            root.enabled,
            COUNT(file.id) AS file_count,
            COALESCE(SUM(CASE
                WHEN file.deleted_at IS NULL
                 AND file.availability_state = 'ready'
                THEN 1 ELSE 0 END), 0) AS ready_file_count,
            sync.scan_id AS last_scan_id,
            root.last_seen_at,
            sync.completed_at
        FROM library_roots root
        JOIN devices device ON device.id = root.owner_device_id
        LEFT JOIN files file ON file.library_root_id = root.id
        LEFT JOIN client_library_sync_state sync
          ON sync.device_id = root.owner_device_id
         AND sync.root_external_id = root.external_id
        WHERE root.root_kind = 'client'
        GROUP BY root.id
        ORDER BY device.name COLLATE NOCASE, display_name COLLATE NOCASE
        "#,
    )
    .fetch_all(pool)
    .await?;
    rows.into_iter()
        .map(|row| {
            let last_seen_at: Option<String> = row.try_get("last_seen_at")?;
            let completed_at: Option<String> = row.try_get("completed_at")?;
            Ok(ClientLibraryRootStatus {
                root_id: row.try_get("root_id")?,
                external_id: row.try_get("external_id")?,
                display_name: row.try_get("display_name")?,
                device_id: row.try_get("device_id")?,
                device_name: row.try_get("device_name")?,
                platform: row.try_get("platform")?,
                path_hint: row.try_get("path_hint")?,
                enabled: row.try_get::<i64, _>("enabled")? != 0,
                file_count: row.try_get("file_count")?,
                ready_file_count: row.try_get("ready_file_count")?,
                last_scan_id: row.try_get("last_scan_id")?,
                last_seen_at: last_seen_at.map(parse_datetime).transpose()?,
                completed_at: completed_at.map(parse_datetime).transpose()?,
            })
        })
        .collect()
}

pub async fn apply_client_mutations(
    pool: &DbPool,
    request: &ClientMutationBatchRequest,
) -> Result<ClientMutationBatchResult> {
    let device_id = request.device_id.trim();
    let device_name = request.device_name.trim();
    if device_id.is_empty() || device_id.len() > 200 {
        bail!("device_id must contain between 1 and 200 characters");
    }
    if device_name.is_empty() || device_name.len() > 300 {
        bail!("device_name must contain between 1 and 300 characters");
    }
    if request.mutations.len() > 500 {
        bail!("a client mutation batch cannot exceed 500 operations");
    }

    let now = Utc::now().to_rfc3339();
    let mut tx = pool.begin().await?;
    sqlx::query(
        r#"
        INSERT INTO devices (
            id, name, platform, token_hash, created_at, last_seen_at
        )
        VALUES (?1, ?2, ?3, 'client-mutation-sync', ?4, ?4)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            platform = COALESCE(excluded.platform, devices.platform),
            last_seen_at = excluded.last_seen_at
        "#,
    )
    .bind(device_id)
    .bind(device_name)
    .bind(&request.platform)
    .bind(&now)
    .execute(&mut *tx)
    .await?;

    let mut applied_ids = Vec::new();
    let mut duplicate_ids = Vec::new();
    for mutation in &request.mutations {
        let mutation_id = mutation.id.trim();
        if mutation_id.is_empty() || mutation_id.len() > 200 {
            bail!("mutation id must contain between 1 and 200 characters");
        }
        let duplicate: Option<i64> = sqlx::query_scalar(
            r#"
            SELECT 1
            FROM client_mutation_receipts
            WHERE device_id = ?1 AND mutation_id = ?2
            "#,
        )
        .bind(device_id)
        .bind(mutation_id)
        .fetch_optional(&mut *tx)
        .await?;
        if duplicate.is_some() {
            duplicate_ids.push(mutation_id.to_string());
            continue;
        }

        let track_title: String = sqlx::query_scalar("SELECT title FROM tracks WHERE id = ?1")
            .bind(mutation.track_id)
            .fetch_one(&mut *tx)
            .await
            .with_context(|| {
                format!(
                    "offline mutation {} references unknown track {}",
                    mutation_id, mutation.track_id
                )
            })?;
        let occurred_at = mutation.occurred_at.to_rfc3339();
        match mutation.kind.as_str() {
            "favorite" => {
                let favorite = mutation
                    .payload
                    .get("is_favorite")
                    .and_then(Value::as_bool)
                    .context("favorite mutation requires payload.is_favorite")?;
                sqlx::query(
                    r#"
                    INSERT INTO user_track_state (
                        track_id, is_favorite, favorite_updated_at,
                        created_at, updated_at
                    )
                    VALUES (?1, ?2, ?3, ?3, ?3)
                    ON CONFLICT(track_id) DO UPDATE SET
                        is_favorite = excluded.is_favorite,
                        favorite_updated_at = excluded.favorite_updated_at,
                        updated_at = excluded.updated_at
                    WHERE user_track_state.favorite_updated_at IS NULL
                       OR user_track_state.favorite_updated_at <= excluded.favorite_updated_at
                    "#,
                )
                .bind(mutation.track_id)
                .bind(if favorite { 1_i64 } else { 0_i64 })
                .bind(&occurred_at)
                .execute(&mut *tx)
                .await?;
            }
            "playback" => {
                let started_at = mutation
                    .payload
                    .get("started_at")
                    .and_then(Value::as_str)
                    .unwrap_or(&occurred_at);
                let ended_at = mutation
                    .payload
                    .get("ended_at")
                    .and_then(Value::as_str)
                    .unwrap_or(&occurred_at);
                DateTime::parse_from_rfc3339(started_at)
                    .context("playback mutation started_at must be RFC 3339")?;
                DateTime::parse_from_rfc3339(ended_at)
                    .context("playback mutation ended_at must be RFC 3339")?;
                let start_position_ms = mutation
                    .payload
                    .get("start_position_ms")
                    .and_then(Value::as_i64)
                    .unwrap_or(0)
                    .max(0);
                let end_position_ms = mutation
                    .payload
                    .get("end_position_ms")
                    .and_then(Value::as_i64)
                    .unwrap_or(start_position_ms)
                    .max(0);
                let reason = mutation
                    .payload
                    .get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("offline");
                if reason.len() > 100 {
                    bail!("playback mutation reason cannot exceed 100 characters");
                }
                let zone_id = format!("offline:{device_id}");
                sqlx::query(
                    r#"
                    INSERT INTO playback_sessions (
                        zone_id, track_id, track_title, started_at,
                        start_position_ms, ended_at, end_position_ms,
                        end_reason, played_ms, created_at, updated_at
                    )
                    VALUES (
                        ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8,
                        MAX(?7 - ?5, 0), ?4, ?6
                    )
                    "#,
                )
                .bind(&zone_id)
                .bind(mutation.track_id)
                .bind(&track_title)
                .bind(started_at)
                .bind(start_position_ms)
                .bind(ended_at)
                .bind(end_position_ms)
                .bind(reason)
                .execute(&mut *tx)
                .await?;
                sqlx::query(
                    r#"
                    INSERT INTO playback_events (
                        zone_id, event_type, track_id, track_title,
                        position_ms, reason, created_at
                    )
                    VALUES (?1, 'play_start', ?2, ?3, ?4, 'offline', ?5)
                    "#,
                )
                .bind(&zone_id)
                .bind(mutation.track_id)
                .bind(&track_title)
                .bind(start_position_ms)
                .bind(started_at)
                .execute(&mut *tx)
                .await?;
                sqlx::query(
                    r#"
                    INSERT INTO playback_events (
                        zone_id, event_type, track_id, track_title,
                        position_ms, reason, created_at
                    )
                    VALUES (?1, 'stop', ?2, ?3, ?4, ?5, ?6)
                    "#,
                )
                .bind(&zone_id)
                .bind(mutation.track_id)
                .bind(&track_title)
                .bind(end_position_ms)
                .bind(reason)
                .bind(ended_at)
                .execute(&mut *tx)
                .await?;
            }
            kind => bail!("unsupported client mutation kind: {kind}"),
        }
        sqlx::query(
            r#"
            INSERT INTO client_mutation_receipts (
                device_id, mutation_id, mutation_kind, occurred_at, applied_at
            )
            VALUES (?1, ?2, ?3, ?4, ?5)
            "#,
        )
        .bind(device_id)
        .bind(mutation_id)
        .bind(&mutation.kind)
        .bind(&occurred_at)
        .bind(&now)
        .execute(&mut *tx)
        .await?;
        applied_ids.push(mutation_id.to_string());
    }
    tx.commit().await?;
    Ok(ClientMutationBatchResult {
        applied_ids,
        duplicate_ids,
    })
}

pub async fn create_distribution_job(
    pool: &DbPool,
    request: &CreateDistributionRequest,
) -> Result<DistributionJobSummary> {
    let target_device_id = request.target_device_id.trim();
    let target_root_external_id = request.target_root_external_id.trim();
    if target_device_id.is_empty() || target_device_id.len() > 200 {
        bail!("target_device_id must contain between 1 and 200 characters");
    }
    if target_root_external_id.is_empty() || target_root_external_id.len() > 300 {
        bail!("target_root_external_id must contain between 1 and 300 characters");
    }
    let quality = request.quality.trim().to_ascii_lowercase();
    let profile_extension = distribution_profile_extension(&quality)?;

    let mut tx = pool.begin().await?;
    let target_exists: Option<i64> = sqlx::query_scalar(
        r#"
        SELECT root.id
        FROM library_roots root
        WHERE root.root_kind = 'client'
          AND root.owner_device_id = ?1
          AND root.external_id = ?2
          AND root.enabled = 1
        "#,
    )
    .bind(target_device_id)
    .bind(target_root_external_id)
    .fetch_optional(&mut *tx)
    .await?;
    if target_exists.is_none() {
        bail!("the target Client library folder is not registered or is disabled");
    }

    let mut track_ids = request
        .track_ids
        .iter()
        .copied()
        .filter(|id| *id > 0)
        .collect::<Vec<_>>();
    for album_id in request.album_ids.iter().copied().filter(|id| *id > 0) {
        track_ids.extend(
            sqlx::query_scalar::<_, i64>(
                r#"
                SELECT id
                FROM tracks
                WHERE album_id = ?1
                ORDER BY COALESCE(disc_number, 1), COALESCE(track_number, 0), id
                "#,
            )
            .bind(album_id)
            .fetch_all(&mut *tx)
            .await?,
        );
    }
    for playlist_id in request.playlist_ids.iter().copied().filter(|id| *id > 0) {
        track_ids.extend(
            sqlx::query_scalar::<_, i64>(
                r#"
                SELECT track_id
                FROM playlist_items
                WHERE playlist_id = ?1
                ORDER BY position, id
                "#,
            )
            .bind(playlist_id)
            .fetch_all(&mut *tx)
            .await?,
        );
    }
    track_ids.sort_unstable();
    track_ids.dedup();
    if track_ids.is_empty() {
        bail!("a distribution job must contain at least one track");
    }
    if track_ids.len() > 5_000 {
        bail!("a distribution job cannot exceed 5000 tracks");
    }

    let now = Utc::now().to_rfc3339();
    let job_id = Uuid::now_v7().to_string();
    sqlx::query(
        r#"
        INSERT INTO distribution_jobs (
            id, target_device_id, target_root_external_id, quality,
            state, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, 'queued', ?5, ?5)
        "#,
    )
    .bind(&job_id)
    .bind(target_device_id)
    .bind(target_root_external_id)
    .bind(&quality)
    .bind(&now)
    .execute(&mut *tx)
    .await?;

    let mut relative_paths = HashSet::new();
    let mut total_bytes = 0_i64;
    let mut completed_items = 0_i64;
    for track_id in &track_ids {
        let source = sqlx::query(
            r#"
            SELECT
                variant.id AS media_variant_id,
                file.id AS source_file_id,
                file.path AS source_file_path,
                file.extension,
                file.size_bytes,
                file.quick_hash,
                replica.source_kind,
                replica.device_id AS source_device_id,
                root.external_id AS source_root_external_id,
                file.relative_path AS source_relative_path,
                track.title,
                track.disc_number,
                track.track_number,
                album.title AS album_title,
                album.album_artist_display,
                (
                    SELECT GROUP_CONCAT(artist.name, ', ')
                    FROM track_artists track_artist
                    JOIN artists artist ON artist.id = track_artist.artist_id
                    WHERE track_artist.track_id = track.id
                      AND track_artist.role = 'primary'
                    ORDER BY track_artist.position
                ) AS artist_display
            FROM tracks track
            JOIN legacy_track_catalog_links link ON link.track_id = track.id
            JOIN release_track_media_variants relation
              ON relation.release_track_id = link.release_track_id
            JOIN media_variants variant ON variant.id = relation.media_variant_id
            JOIN media_replicas replica ON replica.media_variant_id = variant.id
            JOIN files file ON file.id = replica.file_id
            JOIN library_roots root ON root.id = replica.library_root_id
            LEFT JOIN albums album ON album.id = track.album_id
            WHERE track.id = ?1
              AND replica.availability_state = 'ready'
              AND file.deleted_at IS NULL
              AND file.availability_state = 'ready'
            ORDER BY
                CASE WHEN replica.source_kind = 'core' THEN 0 ELSE 1 END,
                root.last_seen_at DESC,
                relation.is_preferred DESC,
                replica.is_primary DESC,
                COALESCE(variant.bit_depth, 0) DESC,
                COALESCE(variant.bitrate, 0) DESC,
                file.id
            LIMIT 1
            "#,
        )
        .bind(track_id)
        .fetch_optional(&mut *tx)
        .await?
        .with_context(|| format!("track {track_id} has no available media replica"))?;
        let media_variant_id: i64 = source.try_get("media_variant_id")?;
        let source_file_id: i64 = source.try_get("source_file_id")?;
        let source_file_path: String = source.try_get("source_file_path")?;
        let source_kind: String = source.try_get("source_kind")?;
        let source_device_id: Option<String> = source.try_get("source_device_id")?;
        let source_root_external_id: Option<String> = source.try_get("source_root_external_id")?;
        let source_relative_path: String = source.try_get("source_relative_path")?;
        let requires_source_upload = source_kind != "core";
        if requires_source_upload
            && (source_device_id.as_deref().is_none_or(str::is_empty)
                || source_root_external_id.as_deref().is_none_or(str::is_empty))
        {
            bail!("track {track_id} has an invalid Client media replica");
        }
        let source_extension: String = source.try_get("extension")?;
        let extension = profile_extension
            .unwrap_or(source_extension.as_str())
            .to_string();
        let size_bytes: i64 = source.try_get("size_bytes")?;
        let title: String = source.try_get("title")?;
        let album_title: Option<String> = source.try_get("album_title")?;
        let album_artist: Option<String> = source.try_get("album_artist_display")?;
        let track_artist: Option<String> = source.try_get("artist_display")?;
        let disc_number: Option<i64> = source.try_get("disc_number")?;
        let track_number: Option<i64> = source.try_get("track_number")?;
        let quick_hash: Option<String> = source.try_get("quick_hash")?;
        let already_present: Option<i64> = if quality == "original" {
            sqlx::query_scalar(
                r#"
                SELECT 1
                FROM media_replicas
                WHERE media_variant_id = ?1
                  AND device_id = ?2
                  AND availability_state = 'ready'
                LIMIT 1
                "#,
            )
            .bind(media_variant_id)
            .bind(target_device_id)
            .fetch_optional(&mut *tx)
            .await?
        } else {
            None
        };
        let artist = track_artist
            .as_deref()
            .or(album_artist.as_deref())
            .unwrap_or("Unknown Artist");
        let album = album_title.as_deref().unwrap_or("Unknown Album");
        let mut relative_path = distribution_relative_path(
            artist,
            album,
            &title,
            disc_number,
            track_number,
            &extension,
        );
        if !relative_paths.insert(relative_path.clone()) {
            let path = Path::new(&relative_path);
            let stem = path
                .file_stem()
                .and_then(|value| value.to_str())
                .unwrap_or("track");
            let parent = path.parent().unwrap_or_else(|| Path::new(""));
            relative_path = parent
                .join(format!("{stem} (track {track_id}).{extension}"))
                .to_string_lossy()
                .replace('\\', "/");
            relative_paths.insert(relative_path.clone());
        }
        let item_state = if already_present.is_some() {
            completed_items += 1;
            "skipped"
        } else if requires_source_upload {
            "awaiting_source"
        } else if quality == "original" {
            total_bytes = total_bytes.saturating_add(size_bytes.max(0));
            "queued"
        } else {
            "preparing"
        };
        let expected_size = if quality == "original" {
            size_bytes.max(0)
        } else {
            0
        };
        let expected_hash = if quality == "original" {
            quick_hash
        } else {
            None
        };
        let content_file_path = if quality == "original" && !requires_source_upload {
            Some(source_file_path)
        } else {
            None
        };
        sqlx::query(
            r#"
            INSERT INTO distribution_items (
                id, job_id, track_id, media_variant_id, source_file_id,
                relative_path, extension, expected_size_bytes,
                expected_quick_hash, content_file_path, state,
                source_device_id, source_root_external_id, source_relative_path,
                created_at, updated_at, completed_at
            )
            VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11,
                ?12, ?13, ?14, ?15, ?15,
                CASE WHEN ?11 = 'skipped' THEN ?15 ELSE NULL END
            )
            "#,
        )
        .bind(Uuid::now_v7().to_string())
        .bind(&job_id)
        .bind(track_id)
        .bind(media_variant_id)
        .bind(source_file_id)
        .bind(relative_path)
        .bind(extension.to_ascii_lowercase())
        .bind(expected_size)
        .bind(expected_hash)
        .bind(content_file_path)
        .bind(item_state)
        .bind(source_device_id)
        .bind(source_root_external_id)
        .bind(source_relative_path)
        .bind(&now)
        .execute(&mut *tx)
        .await?;
    }

    sqlx::query(
        r#"
        UPDATE distribution_jobs
        SET total_items = ?1,
            completed_items = ?2,
            total_bytes = ?3,
            updated_at = ?4
        WHERE id = ?5
        "#,
    )
    .bind(track_ids.len() as i64)
    .bind(completed_items)
    .bind(total_bytes)
    .bind(&now)
    .bind(&job_id)
    .execute(&mut *tx)
    .await?;
    refresh_distribution_job_totals(&mut tx, &job_id, &now).await?;
    tx.commit().await?;
    get_distribution_job(pool, &job_id).await
}

pub async fn list_distribution_jobs(
    pool: &DbPool,
    target_device_id: Option<&str>,
    limit: u32,
) -> Result<Vec<DistributionJobSummary>> {
    let rows = sqlx::query(
        r#"
        SELECT
            job.*,
            device.name AS target_device_name,
            COALESCE(NULLIF(root.display_name, ''), root.external_id)
                AS target_root_name
        FROM distribution_jobs job
        JOIN devices device ON device.id = job.target_device_id
        JOIN library_roots root
          ON root.root_kind = 'client'
         AND root.owner_device_id = job.target_device_id
         AND root.external_id = job.target_root_external_id
        WHERE (?1 IS NULL OR job.target_device_id = ?1)
        ORDER BY job.created_at DESC
        LIMIT ?2
        "#,
    )
    .bind(target_device_id)
    .bind(limit.clamp(1, 500))
    .fetch_all(pool)
    .await?;
    rows.into_iter().map(row_to_distribution_job).collect()
}

pub async fn get_distribution_job(pool: &DbPool, job_id: &str) -> Result<DistributionJobSummary> {
    let row = sqlx::query(
        r#"
        SELECT
            job.*,
            device.name AS target_device_name,
            COALESCE(NULLIF(root.display_name, ''), root.external_id)
                AS target_root_name
        FROM distribution_jobs job
        JOIN devices device ON device.id = job.target_device_id
        JOIN library_roots root
          ON root.root_kind = 'client'
         AND root.owner_device_id = job.target_device_id
         AND root.external_id = job.target_root_external_id
        WHERE job.id = ?1
        "#,
    )
    .bind(job_id)
    .fetch_one(pool)
    .await?;
    row_to_distribution_job(row)
}

pub async fn claim_distribution_task(
    pool: &DbPool,
    device_id: &str,
) -> Result<Option<DistributionTaskAssignment>> {
    let device_id = device_id.trim();
    if device_id.is_empty() || device_id.len() > 200 {
        bail!("device_id must contain between 1 and 200 characters");
    }
    let now = Utc::now();
    let now_text = now.to_rfc3339();
    let lease_text = (now + chrono::Duration::minutes(30)).to_rfc3339();
    let mut tx = pool.begin().await?;
    sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = CASE WHEN attempt_count >= 3 THEN 'failed' ELSE 'queued' END,
            error = CASE
                WHEN attempt_count >= 3 THEN 'delivery lease expired after 3 attempts'
                ELSE error
            END,
            lease_expires_at = NULL,
            updated_at = ?1
        WHERE state = 'transferring'
          AND lease_expires_at IS NOT NULL
          AND lease_expires_at < ?1
          AND job_id IN (
              SELECT id FROM distribution_jobs WHERE target_device_id = ?2
          )
        "#,
    )
    .bind(&now_text)
    .bind(device_id)
    .execute(&mut *tx)
    .await?;

    let candidate: Option<String> = sqlx::query_scalar(
        r#"
        SELECT item.id
        FROM distribution_items item
        JOIN distribution_jobs job ON job.id = item.job_id
        WHERE job.target_device_id = ?1
          AND job.state NOT IN ('cancelled', 'completed', 'completed_with_errors')
          AND item.state = 'queued'
        ORDER BY job.created_at, item.created_at
        LIMIT 1
        "#,
    )
    .bind(device_id)
    .fetch_optional(&mut *tx)
    .await?;
    let Some(task_id) = candidate else {
        tx.commit().await?;
        return Ok(None);
    };
    let claimed = sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = 'transferring',
            attempt_count = attempt_count + 1,
            claimed_at = ?1,
            lease_expires_at = ?2,
            error = NULL,
            updated_at = ?1
        WHERE id = ?3 AND state = 'queued'
        "#,
    )
    .bind(&now_text)
    .bind(&lease_text)
    .bind(&task_id)
    .execute(&mut *tx)
    .await?;
    if claimed.rows_affected() == 0 {
        tx.commit().await?;
        return Ok(None);
    }
    sqlx::query(
        r#"
        UPDATE distribution_jobs
        SET state = 'transferring', updated_at = ?1
        WHERE id = (SELECT job_id FROM distribution_items WHERE id = ?2)
          AND state = 'queued'
        "#,
    )
    .bind(&now_text)
    .bind(&task_id)
    .execute(&mut *tx)
    .await?;
    let row = sqlx::query(
        r#"
        SELECT
            item.id,
            item.job_id,
            item.track_id,
            track.title,
            album.title AS album_title,
            (
                SELECT GROUP_CONCAT(artist.name, ', ')
                FROM track_artists track_artist
                JOIN artists artist ON artist.id = track_artist.artist_id
                WHERE track_artist.track_id = track.id
                  AND track_artist.role = 'primary'
                ORDER BY track_artist.position
            ) AS artist_display,
            job.target_root_external_id,
            item.relative_path,
            item.extension,
            item.expected_size_bytes,
            item.expected_quick_hash,
            item.attempt_count
        FROM distribution_items item
        JOIN distribution_jobs job ON job.id = item.job_id
        JOIN tracks track ON track.id = item.track_id
        LEFT JOIN albums album ON album.id = track.album_id
        WHERE item.id = ?1
        "#,
    )
    .bind(&task_id)
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Some(DistributionTaskAssignment {
        id: row.try_get("id")?,
        job_id: row.try_get("job_id")?,
        track_id: row.try_get("track_id")?,
        title: row.try_get("title")?,
        artist_display: row.try_get("artist_display")?,
        album_title: row.try_get("album_title")?,
        target_root_external_id: row.try_get("target_root_external_id")?,
        relative_path: row.try_get("relative_path")?,
        extension: row.try_get("extension")?,
        expected_size_bytes: row.try_get("expected_size_bytes")?,
        expected_quick_hash: row.try_get("expected_quick_hash")?,
        attempt_count: row.try_get("attempt_count")?,
        content_path: format!("/distributions/tasks/{task_id}/content"),
    }))
}

pub async fn update_distribution_task(
    pool: &DbPool,
    task_id: &str,
    progress: &DistributionTaskProgress,
) -> Result<DistributionJobSummary> {
    let state = progress.state.trim().to_ascii_lowercase();
    if !matches!(state.as_str(), "progress" | "completed" | "failed") {
        bail!("distribution task state must be progress, completed, or failed");
    }
    let now = Utc::now();
    let now_text = now.to_rfc3339();
    let lease_text = (now + chrono::Duration::minutes(30)).to_rfc3339();
    let mut tx = pool.begin().await?;
    let row = sqlx::query(
        r#"
        SELECT
            item.job_id,
            item.state,
            item.attempt_count,
            item.expected_size_bytes,
            job.target_device_id
        FROM distribution_items item
        JOIN distribution_jobs job ON job.id = item.job_id
        WHERE item.id = ?1
        "#,
    )
    .bind(task_id)
    .fetch_one(&mut *tx)
    .await?;
    let job_id: String = row.try_get("job_id")?;
    let target_device_id: String = row.try_get("target_device_id")?;
    if target_device_id != progress.device_id.trim() {
        bail!("this distribution task belongs to another Client");
    }
    let current_state: String = row.try_get("state")?;
    if matches!(
        current_state.as_str(),
        "completed" | "skipped" | "cancelled"
    ) {
        tx.commit().await?;
        return get_distribution_job(pool, &job_id).await;
    }
    let expected_size: i64 = row.try_get("expected_size_bytes")?;
    let transferred = progress.transferred_bytes.clamp(0, expected_size.max(0));
    match state.as_str() {
        "progress" => {
            sqlx::query(
                r#"
                UPDATE distribution_items
                SET transferred_bytes = MAX(transferred_bytes, ?1),
                    lease_expires_at = ?2,
                    updated_at = ?3
                WHERE id = ?4 AND state = 'transferring'
                "#,
            )
            .bind(transferred)
            .bind(lease_text)
            .bind(&now_text)
            .bind(task_id)
            .execute(&mut *tx)
            .await?;
        }
        "completed" => {
            if transferred != expected_size {
                bail!(
                    "completed distribution size {transferred} does not match expected size {expected_size}"
                );
            }
            sqlx::query(
                r#"
                UPDATE distribution_items
                SET state = 'completed',
                    transferred_bytes = expected_size_bytes,
                    lease_expires_at = NULL,
                    error = NULL,
                    completed_at = ?1,
                    updated_at = ?1
                WHERE id = ?2
                "#,
            )
            .bind(&now_text)
            .bind(task_id)
            .execute(&mut *tx)
            .await?;
        }
        "failed" => {
            let attempt_count: i64 = row.try_get("attempt_count")?;
            let retry = progress.retryable && attempt_count < 3;
            sqlx::query(
                r#"
                UPDATE distribution_items
                SET state = ?1,
                    transferred_bytes = ?2,
                    lease_expires_at = NULL,
                    error = ?3,
                    completed_at = CASE WHEN ?1 = 'failed' THEN ?4 ELSE NULL END,
                    updated_at = ?4
                WHERE id = ?5
                "#,
            )
            .bind(if retry { "queued" } else { "failed" })
            .bind(transferred)
            .bind(
                progress
                    .error
                    .as_deref()
                    .unwrap_or("Client delivery failed"),
            )
            .bind(&now_text)
            .bind(task_id)
            .execute(&mut *tx)
            .await?;
        }
        _ => unreachable!(),
    }
    refresh_distribution_job_totals(&mut tx, &job_id, &now_text).await?;
    tx.commit().await?;
    get_distribution_job(pool, &job_id).await
}

pub async fn distribution_content_source(
    pool: &DbPool,
    task_id: &str,
    device_id: &str,
) -> Result<DistributionContentSource> {
    let row = sqlx::query(
        r#"
        SELECT COALESCE(item.content_file_path, file.path) AS path, item.extension
        FROM distribution_items item
        JOIN distribution_jobs job ON job.id = item.job_id
        JOIN files file ON file.id = item.source_file_id
        WHERE item.id = ?1
          AND job.target_device_id = ?2
          AND job.state <> 'cancelled'
          AND item.state = 'transferring'
          AND file.deleted_at IS NULL
        "#,
    )
    .bind(task_id)
    .bind(device_id)
    .fetch_one(pool)
    .await?;
    Ok(DistributionContentSource {
        path: row.try_get("path")?,
        extension: row.try_get("extension")?,
    })
}

#[derive(Debug, Clone)]
pub struct DistributionSourceUploadExpectation {
    pub expected_size_bytes: i64,
    pub expected_quick_hash: Option<String>,
    pub extension: String,
}

pub async fn claim_distribution_source_task(
    pool: &DbPool,
    device_id: &str,
) -> Result<Option<DistributionSourceTaskAssignment>> {
    let device_id = device_id.trim();
    if device_id.is_empty() || device_id.len() > 200 {
        bail!("device_id must contain between 1 and 200 characters");
    }
    let now = Utc::now();
    let now_text = now.to_rfc3339();
    let lease_text = (now + chrono::Duration::minutes(30)).to_rfc3339();
    let mut tx = pool.begin().await?;
    let expired_jobs = sqlx::query_scalar::<_, String>(
        r#"
        SELECT DISTINCT job_id
        FROM distribution_items
        WHERE source_device_id = ?1
          AND state = 'source_uploading'
          AND source_upload_lease_expires_at IS NOT NULL
          AND source_upload_lease_expires_at < ?2
        "#,
    )
    .bind(device_id)
    .bind(&now_text)
    .fetch_all(&mut *tx)
    .await?;
    sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = CASE
                WHEN source_upload_attempt_count >= 3 THEN 'failed'
                ELSE 'awaiting_source'
            END,
            error = CASE
                WHEN source_upload_attempt_count >= 3
                    THEN 'source upload lease expired after 3 attempts'
                ELSE error
            END,
            source_upload_lease_expires_at = NULL,
            updated_at = ?1,
            completed_at = CASE
                WHEN source_upload_attempt_count >= 3 THEN ?1
                ELSE NULL
            END
        WHERE source_device_id = ?2
          AND state = 'source_uploading'
          AND source_upload_lease_expires_at IS NOT NULL
          AND source_upload_lease_expires_at < ?1
        "#,
    )
    .bind(&now_text)
    .bind(device_id)
    .execute(&mut *tx)
    .await?;
    for job_id in expired_jobs {
        refresh_distribution_job_totals(&mut tx, &job_id, &now_text).await?;
    }

    let candidate: Option<String> = sqlx::query_scalar(
        r#"
        SELECT item.id
        FROM distribution_items item
        JOIN distribution_jobs job ON job.id = item.job_id
        WHERE item.source_device_id = ?1
          AND item.state = 'awaiting_source'
          AND job.state NOT IN ('cancelled', 'completed', 'completed_with_errors')
        ORDER BY job.created_at, item.created_at
        LIMIT 1
        "#,
    )
    .bind(device_id)
    .fetch_optional(&mut *tx)
    .await?;
    let Some(task_id) = candidate else {
        tx.commit().await?;
        return Ok(None);
    };
    let claimed = sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = 'source_uploading',
            source_upload_attempt_count = source_upload_attempt_count + 1,
            source_upload_claimed_at = ?1,
            source_upload_lease_expires_at = ?2,
            error = NULL,
            updated_at = ?1
        WHERE id = ?3
          AND source_device_id = ?4
          AND state = 'awaiting_source'
        "#,
    )
    .bind(&now_text)
    .bind(&lease_text)
    .bind(&task_id)
    .bind(device_id)
    .execute(&mut *tx)
    .await?;
    if claimed.rows_affected() == 0 {
        tx.commit().await?;
        return Ok(None);
    }
    let row = sqlx::query(
        r#"
        SELECT
            item.id,
            item.job_id,
            item.track_id,
            track.title,
            item.source_root_external_id,
            item.source_relative_path,
            file.size_bytes,
            file.quick_hash,
            item.source_upload_attempt_count
        FROM distribution_items item
        JOIN tracks track ON track.id = item.track_id
        JOIN files file ON file.id = item.source_file_id
        WHERE item.id = ?1
        "#,
    )
    .bind(&task_id)
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Some(DistributionSourceTaskAssignment {
        id: row.try_get("id")?,
        job_id: row.try_get("job_id")?,
        track_id: row.try_get("track_id")?,
        title: row.try_get("title")?,
        source_root_external_id: row.try_get("source_root_external_id")?,
        source_relative_path: row.try_get("source_relative_path")?,
        expected_size_bytes: row.try_get("size_bytes")?,
        expected_quick_hash: row.try_get("quick_hash")?,
        attempt_count: row.try_get("source_upload_attempt_count")?,
        upload_path: format!("/distributions/source-tasks/{task_id}/content"),
    }))
}

pub async fn distribution_source_upload_expectation(
    pool: &DbPool,
    task_id: &str,
    device_id: &str,
) -> Result<DistributionSourceUploadExpectation> {
    let row = sqlx::query(
        r#"
        SELECT file.size_bytes, file.quick_hash, file.extension
        FROM distribution_items item
        JOIN distribution_jobs job ON job.id = item.job_id
        JOIN files file ON file.id = item.source_file_id
        WHERE item.id = ?1
          AND item.source_device_id = ?2
          AND item.state = 'source_uploading'
          AND job.state <> 'cancelled'
          AND file.deleted_at IS NULL
          AND file.availability_state = 'ready'
        "#,
    )
    .bind(task_id)
    .bind(device_id.trim())
    .fetch_one(pool)
    .await?;
    Ok(DistributionSourceUploadExpectation {
        expected_size_bytes: row.try_get("size_bytes")?,
        expected_quick_hash: row.try_get("quick_hash")?,
        extension: row.try_get("extension")?,
    })
}

pub async fn complete_distribution_source_task(
    pool: &DbPool,
    task_id: &str,
    device_id: &str,
    content_file_path: &Path,
    actual_size_bytes: i64,
    actual_quick_hash: &str,
) -> Result<DistributionJobSummary> {
    let now = Utc::now().to_rfc3339();
    let mut tx = pool.begin().await?;
    let row = sqlx::query(
        r#"
        SELECT
            item.job_id,
            item.source_device_id,
            item.state,
            file.size_bytes,
            file.quick_hash,
            job.quality
        FROM distribution_items item
        JOIN distribution_jobs job ON job.id = item.job_id
        JOIN files file ON file.id = item.source_file_id
        WHERE item.id = ?1
        "#,
    )
    .bind(task_id)
    .fetch_one(&mut *tx)
    .await?;
    let job_id: String = row.try_get("job_id")?;
    if row
        .try_get::<Option<String>, _>("source_device_id")?
        .as_deref()
        != Some(device_id.trim())
    {
        bail!("this source task belongs to another Client");
    }
    if row.try_get::<String, _>("state")? != "source_uploading" {
        bail!("the distribution source task is no longer active");
    }
    let expected_size: i64 = row.try_get("size_bytes")?;
    if actual_size_bytes != expected_size {
        bail!(
            "uploaded source size {actual_size_bytes} does not match expected size {expected_size}"
        );
    }
    let expected_hash: Option<String> = row.try_get("quick_hash")?;
    if expected_hash
        .as_deref()
        .is_some_and(|expected| !expected.eq_ignore_ascii_case(actual_quick_hash))
    {
        bail!("uploaded source failed its content verification");
    }
    let quality: String = row.try_get("quality")?;
    let next_state = if quality == "original" {
        "queued"
    } else {
        "preparing"
    };
    let updated = sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = ?1,
            content_file_path = ?2,
            source_upload_lease_expires_at = NULL,
            error = NULL,
            updated_at = ?3
        WHERE id = ?4 AND state = 'source_uploading'
        "#,
    )
    .bind(next_state)
    .bind(normalize_path(content_file_path))
    .bind(&now)
    .bind(task_id)
    .execute(&mut *tx)
    .await?;
    if updated.rows_affected() == 0 {
        bail!("the distribution source task is no longer active");
    }
    refresh_distribution_job_totals(&mut tx, &job_id, &now).await?;
    tx.commit().await?;
    get_distribution_job(pool, &job_id).await
}

pub async fn fail_distribution_source_task(
    pool: &DbPool,
    task_id: &str,
    device_id: &str,
    retryable: bool,
    error: &str,
) -> Result<DistributionJobSummary> {
    let now = Utc::now().to_rfc3339();
    let mut tx = pool.begin().await?;
    let row = sqlx::query(
        r#"
        SELECT job_id, source_device_id, state, source_upload_attempt_count
        FROM distribution_items
        WHERE id = ?1
        "#,
    )
    .bind(task_id)
    .fetch_one(&mut *tx)
    .await?;
    let job_id: String = row.try_get("job_id")?;
    if row
        .try_get::<Option<String>, _>("source_device_id")?
        .as_deref()
        != Some(device_id.trim())
    {
        bail!("this source task belongs to another Client");
    }
    if row.try_get::<String, _>("state")? != "source_uploading" {
        tx.commit().await?;
        return get_distribution_job(pool, &job_id).await;
    }
    let attempts: i64 = row.try_get("source_upload_attempt_count")?;
    let should_retry = retryable && attempts < 3;
    let message = error.chars().take(2_000).collect::<String>();
    sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = ?1,
            source_upload_lease_expires_at = NULL,
            error = ?2,
            completed_at = CASE WHEN ?1 = 'failed' THEN ?3 ELSE NULL END,
            updated_at = ?3
        WHERE id = ?4
        "#,
    )
    .bind(if should_retry {
        "awaiting_source"
    } else {
        "failed"
    })
    .bind(message)
    .bind(&now)
    .bind(task_id)
    .execute(&mut *tx)
    .await?;
    refresh_distribution_job_totals(&mut tx, &job_id, &now).await?;
    tx.commit().await?;
    get_distribution_job(pool, &job_id).await
}

pub async fn claim_distribution_transcode_task(
    pool: &DbPool,
) -> Result<Option<DistributionTranscodeTask>> {
    let now = Utc::now();
    let now_text = now.to_rfc3339();
    let lease_text = (now + chrono::Duration::hours(6)).to_rfc3339();
    let mut tx = pool.begin().await?;
    let expired_jobs = sqlx::query_scalar::<_, String>(
        r#"
        SELECT DISTINCT job_id
        FROM distribution_items
        WHERE state = 'transcoding'
          AND transcode_lease_expires_at IS NOT NULL
          AND transcode_lease_expires_at < ?1
        "#,
    )
    .bind(&now_text)
    .fetch_all(&mut *tx)
    .await?;
    sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = CASE
                WHEN transcode_attempt_count >= 3 THEN 'failed'
                ELSE 'preparing'
            END,
            error = CASE
                WHEN transcode_attempt_count >= 3
                    THEN 'transcoding lease expired after 3 attempts'
                ELSE error
            END,
            transcode_lease_expires_at = NULL,
            updated_at = ?1,
            completed_at = CASE
                WHEN transcode_attempt_count >= 3 THEN ?1
                ELSE NULL
            END
        WHERE state = 'transcoding'
          AND transcode_lease_expires_at IS NOT NULL
          AND transcode_lease_expires_at < ?1
        "#,
    )
    .bind(&now_text)
    .execute(&mut *tx)
    .await?;
    for job_id in expired_jobs {
        refresh_distribution_job_totals(&mut tx, &job_id, &now_text).await?;
    }

    let candidate: Option<String> = sqlx::query_scalar(
        r#"
        SELECT item.id
        FROM distribution_items item
        JOIN distribution_jobs job ON job.id = item.job_id
        WHERE item.state = 'preparing'
          AND job.state NOT IN ('cancelled', 'completed', 'completed_with_errors')
        ORDER BY job.created_at, item.created_at
        LIMIT 1
        "#,
    )
    .fetch_optional(&mut *tx)
    .await?;
    let Some(task_id) = candidate else {
        tx.commit().await?;
        return Ok(None);
    };
    let claimed = sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = 'transcoding',
            transcode_attempt_count = transcode_attempt_count + 1,
            transcode_claimed_at = ?1,
            transcode_lease_expires_at = ?2,
            error = NULL,
            updated_at = ?1
        WHERE id = ?3 AND state = 'preparing'
        "#,
    )
    .bind(&now_text)
    .bind(&lease_text)
    .bind(&task_id)
    .execute(&mut *tx)
    .await?;
    if claimed.rows_affected() == 0 {
        tx.commit().await?;
        return Ok(None);
    }
    let row = sqlx::query(
        r#"
        SELECT
            item.id,
            item.job_id,
            job.quality,
            COALESCE(item.content_file_path, file.path) AS source_path,
            file.size_bytes,
            file.modified_at,
            file.quick_hash
        FROM distribution_items item
        JOIN distribution_jobs job ON job.id = item.job_id
        JOIN files file ON file.id = item.source_file_id
        WHERE item.id = ?1
          AND file.deleted_at IS NULL
          AND file.availability_state = 'ready'
        "#,
    )
    .bind(&task_id)
    .fetch_one(&mut *tx)
    .await?;
    let quick_hash: Option<String> = row.try_get("quick_hash")?;
    let source_signature = quick_hash
        .filter(|value| !value.trim().is_empty())
        .map(|value| format!("quick:{value}"))
        .unwrap_or_else(|| {
            format!(
                "file:{}:{}:{}",
                row.try_get::<i64, _>("size_bytes").unwrap_or_default(),
                row.try_get::<String, _>("modified_at").unwrap_or_default(),
                row.try_get::<String, _>("source_path").unwrap_or_default()
            )
        });
    let task = DistributionTranscodeTask {
        id: row.try_get("id")?,
        job_id: row.try_get("job_id")?,
        quality: row.try_get("quality")?,
        source_path: row.try_get("source_path")?,
        source_signature,
    };
    tx.commit().await?;
    Ok(Some(task))
}

pub async fn complete_distribution_transcode_task(
    pool: &DbPool,
    task_id: &str,
    content_file_path: &Path,
    extension: &str,
    expected_size_bytes: i64,
    expected_quick_hash: &str,
) -> Result<DistributionJobSummary> {
    if expected_size_bytes <= 0 {
        bail!("a transcoded file must not be empty");
    }
    let extension = extension
        .trim()
        .trim_start_matches('.')
        .to_ascii_lowercase();
    if extension.is_empty() || !extension.chars().all(|value| value.is_ascii_alphanumeric()) {
        bail!("invalid transcoded file extension");
    }
    let now = Utc::now().to_rfc3339();
    let mut tx = pool.begin().await?;
    let job_id: String = sqlx::query_scalar("SELECT job_id FROM distribution_items WHERE id = ?1")
        .bind(task_id)
        .fetch_one(&mut *tx)
        .await?;
    let updated = sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = 'queued',
            content_file_path = ?1,
            extension = ?2,
            expected_size_bytes = ?3,
            expected_quick_hash = ?4,
            transferred_bytes = 0,
            transcode_lease_expires_at = NULL,
            error = NULL,
            updated_at = ?5
        WHERE id = ?6 AND state = 'transcoding'
        "#,
    )
    .bind(normalize_path(content_file_path))
    .bind(extension)
    .bind(expected_size_bytes)
    .bind(expected_quick_hash)
    .bind(&now)
    .bind(task_id)
    .execute(&mut *tx)
    .await?;
    if updated.rows_affected() == 0 {
        bail!("the distribution transcode task is no longer active");
    }
    refresh_distribution_job_totals(&mut tx, &job_id, &now).await?;
    tx.commit().await?;
    get_distribution_job(pool, &job_id).await
}

pub async fn active_distribution_content_paths(pool: &DbPool) -> Result<Vec<String>> {
    Ok(sqlx::query_scalar(
        r#"
        SELECT DISTINCT content_file_path
        FROM distribution_items
        WHERE content_file_path IS NOT NULL
          AND state IN ('preparing', 'transcoding', 'queued', 'transferring')
        "#,
    )
    .fetch_all(pool)
    .await?)
}

pub async fn distribution_content_paths_for_job(
    pool: &DbPool,
    job_id: &str,
) -> Result<Vec<String>> {
    Ok(sqlx::query_scalar(
        r#"
        SELECT DISTINCT content_file_path
        FROM distribution_items
        WHERE job_id = ?1 AND content_file_path IS NOT NULL
        "#,
    )
    .bind(job_id)
    .fetch_all(pool)
    .await?)
}

pub async fn fail_distribution_transcode_task(
    pool: &DbPool,
    task_id: &str,
    retryable: bool,
    error: &str,
) -> Result<DistributionJobSummary> {
    let now = Utc::now().to_rfc3339();
    let mut tx = pool.begin().await?;
    let row = sqlx::query(
        r#"
        SELECT job_id, state, transcode_attempt_count
        FROM distribution_items
        WHERE id = ?1
        "#,
    )
    .bind(task_id)
    .fetch_one(&mut *tx)
    .await?;
    let job_id: String = row.try_get("job_id")?;
    let state: String = row.try_get("state")?;
    if state != "transcoding" {
        tx.commit().await?;
        return get_distribution_job(pool, &job_id).await;
    }
    let attempts: i64 = row.try_get("transcode_attempt_count")?;
    let should_retry = retryable && attempts < 3;
    let message = error.chars().take(2_000).collect::<String>();
    sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = ?1,
            transcode_lease_expires_at = NULL,
            error = ?2,
            completed_at = CASE WHEN ?1 = 'failed' THEN ?3 ELSE NULL END,
            updated_at = ?3
        WHERE id = ?4
        "#,
    )
    .bind(if should_retry { "preparing" } else { "failed" })
    .bind(message)
    .bind(&now)
    .bind(task_id)
    .execute(&mut *tx)
    .await?;
    refresh_distribution_job_totals(&mut tx, &job_id, &now).await?;
    tx.commit().await?;
    get_distribution_job(pool, &job_id).await
}

pub async fn cancel_distribution_job(
    pool: &DbPool,
    job_id: &str,
) -> Result<DistributionJobSummary> {
    let now = Utc::now().to_rfc3339();
    let mut tx = pool.begin().await?;
    let updated = sqlx::query(
        r#"
        UPDATE distribution_jobs
        SET state = 'cancelled', updated_at = ?1, completed_at = ?1
        WHERE id = ?2
          AND state NOT IN ('completed', 'completed_with_errors', 'cancelled')
        "#,
    )
    .bind(&now)
    .bind(job_id)
    .execute(&mut *tx)
    .await?;
    if updated.rows_affected() > 0 {
        sqlx::query(
            r#"
            UPDATE distribution_items
            SET state = 'cancelled',
                lease_expires_at = NULL,
                source_upload_lease_expires_at = NULL,
                transcode_lease_expires_at = NULL,
                updated_at = ?1
            WHERE job_id = ?2
              AND state IN (
                  'awaiting_source', 'source_uploading',
                  'preparing', 'transcoding', 'queued', 'transferring'
              )
            "#,
        )
        .bind(&now)
        .bind(job_id)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    get_distribution_job(pool, job_id).await
}

async fn refresh_distribution_job_totals(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    job_id: &str,
    now: &str,
) -> Result<()> {
    let totals = sqlx::query(
        r#"
        SELECT
            COUNT(*) AS total_items,
            COALESCE(SUM(CASE WHEN state IN ('completed', 'skipped') THEN 1 ELSE 0 END), 0)
                AS completed_items,
            COALESCE(SUM(CASE WHEN state = 'failed' THEN 1 ELSE 0 END), 0)
                AS failed_items,
            COALESCE(SUM(CASE
                WHEN state = 'skipped' THEN 0
                WHEN state = 'completed' THEN expected_size_bytes
                ELSE MIN(transferred_bytes, expected_size_bytes)
            END), 0) AS transferred_bytes,
            COALESCE(SUM(CASE
                WHEN state = 'skipped' THEN 0
                ELSE expected_size_bytes
            END), 0) AS total_bytes,
            COALESCE(SUM(CASE WHEN state IN ('preparing', 'transcoding') THEN 1 ELSE 0 END), 0)
                AS preparing_items,
            COALESCE(SUM(CASE WHEN state IN ('awaiting_source', 'source_uploading') THEN 1 ELSE 0 END), 0)
                AS source_items,
            COALESCE(SUM(CASE WHEN state = 'transferring' THEN 1 ELSE 0 END), 0)
                AS transferring_items,
            MAX(CASE WHEN state = 'failed' THEN error ELSE NULL END) AS error
        FROM distribution_items
        WHERE job_id = ?1
        "#,
    )
    .bind(job_id)
    .fetch_one(&mut **tx)
    .await?;
    let total_items: i64 = totals.try_get("total_items")?;
    let completed_items: i64 = totals.try_get("completed_items")?;
    let failed_items: i64 = totals.try_get("failed_items")?;
    let terminal = completed_items + failed_items >= total_items;
    let state = if terminal && failed_items > 0 {
        "completed_with_errors"
    } else if terminal {
        "completed"
    } else if totals.try_get::<i64, _>("transferring_items")? > 0 {
        "transferring"
    } else if totals.try_get::<i64, _>("preparing_items")? > 0 {
        "preparing"
    } else if totals.try_get::<i64, _>("source_items")? > 0 {
        "awaiting_source"
    } else {
        "queued"
    };
    sqlx::query(
        r#"
        UPDATE distribution_jobs
        SET state = ?1,
            completed_items = ?2,
            failed_items = ?3,
            transferred_bytes = ?4,
            total_bytes = ?5,
            error = ?6,
            updated_at = ?7,
            completed_at = CASE WHEN ?8 THEN ?7 ELSE NULL END
        WHERE id = ?9 AND state <> 'cancelled'
        "#,
    )
    .bind(state)
    .bind(completed_items)
    .bind(failed_items)
    .bind(totals.try_get::<i64, _>("transferred_bytes")?)
    .bind(totals.try_get::<i64, _>("total_bytes")?)
    .bind(totals.try_get::<Option<String>, _>("error")?)
    .bind(now)
    .bind(terminal)
    .bind(job_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

fn row_to_distribution_job(row: sqlx::sqlite::SqliteRow) -> Result<DistributionJobSummary> {
    let created_at: String = row.try_get("created_at")?;
    let updated_at: String = row.try_get("updated_at")?;
    let completed_at: Option<String> = row.try_get("completed_at")?;
    Ok(DistributionJobSummary {
        id: row.try_get("id")?,
        target_device_id: row.try_get("target_device_id")?,
        target_device_name: row.try_get("target_device_name")?,
        target_root_external_id: row.try_get("target_root_external_id")?,
        target_root_name: row.try_get("target_root_name")?,
        quality: row.try_get("quality")?,
        state: row.try_get("state")?,
        total_items: row.try_get("total_items")?,
        completed_items: row.try_get("completed_items")?,
        failed_items: row.try_get("failed_items")?,
        total_bytes: row.try_get("total_bytes")?,
        transferred_bytes: row.try_get("transferred_bytes")?,
        error: row.try_get("error")?,
        created_at: parse_datetime(created_at)?,
        updated_at: parse_datetime(updated_at)?,
        completed_at: completed_at.map(parse_datetime).transpose()?,
    })
}

fn distribution_profile_extension(quality: &str) -> Result<Option<&'static str>> {
    match quality {
        "original" => Ok(None),
        "flac" | "lossless" => Ok(Some("flac")),
        "aac-256" | "high" | "aac-160" | "balanced" | "aac-96" | "data-saver" => Ok(Some("m4a")),
        "opus-160" | "opus-96" => Ok(Some("opus")),
        _ => bail!("unknown distribution quality profile {quality}"),
    }
}

fn distribution_relative_path(
    artist: &str,
    album: &str,
    title: &str,
    disc_number: Option<i64>,
    track_number: Option<i64>,
    extension: &str,
) -> String {
    let artist = safe_distribution_path_component(artist, "Unknown Artist");
    let album = safe_distribution_path_component(album, "Unknown Album");
    let title = safe_distribution_path_component(title, "Unknown Track");
    let extension = extension
        .chars()
        .filter(|value| value.is_ascii_alphanumeric())
        .collect::<String>()
        .to_ascii_lowercase();
    let extension = if extension.is_empty() {
        "audio".to_string()
    } else {
        extension
    };
    let prefix = match (disc_number, track_number) {
        (Some(disc), Some(track)) if disc > 1 => format!("{disc}-{track:02}"),
        (_, Some(track)) => format!("{track:02}"),
        _ => "00".to_string(),
    };
    format!("{artist}/{album}/{prefix} - {title}.{extension}")
}

fn safe_distribution_path_component(value: &str, fallback: &str) -> String {
    let mut safe = value
        .chars()
        .map(|character| {
            if character.is_control()
                || matches!(
                    character,
                    '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*'
                )
            {
                '_'
            } else {
                character
            }
        })
        .collect::<String>();
    safe = safe.trim().trim_matches('.').trim().to_string();
    if safe.is_empty() {
        safe = fallback.to_string();
    }
    if safe.chars().count() > 120 {
        safe = safe.chars().take(120).collect();
    }
    let reserved = safe
        .split('.')
        .next()
        .unwrap_or_default()
        .to_ascii_uppercase();
    if matches!(
        reserved.as_str(),
        "CON"
            | "PRN"
            | "AUX"
            | "NUL"
            | "COM1"
            | "COM2"
            | "COM3"
            | "COM4"
            | "COM5"
            | "COM6"
            | "COM7"
            | "COM8"
            | "COM9"
            | "LPT1"
            | "LPT2"
            | "LPT3"
            | "LPT4"
            | "LPT5"
            | "LPT6"
            | "LPT7"
            | "LPT8"
            | "LPT9"
    ) {
        safe.insert(0, '_');
    }
    safe
}

fn client_track_manifest_to_ingest(
    metadata: &ClientTrackManifest,
    relative_path: &str,
) -> TrackIngest {
    let fallback_title = Path::new(relative_path)
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("Unknown track")
        .to_string();
    TrackIngest {
        title: if metadata.title.trim().is_empty() {
            fallback_title
        } else {
            metadata.title.trim().to_string()
        },
        sort_title: metadata.sort_title.clone(),
        subtitle: metadata.subtitle.clone(),
        album: metadata.album.clone(),
        track_artists: metadata.track_artists.clone(),
        album_artists: metadata.album_artists.clone(),
        composers: metadata.composers.clone(),
        lyricists: metadata.lyricists.clone(),
        genres: metadata.genres.clone(),
        disc_number: metadata.disc_number,
        disc_total: metadata.disc_total,
        track_number: metadata.track_number,
        track_total: metadata.track_total,
        duration_ms: metadata.duration_ms,
        date: metadata.date.clone(),
        year: metadata.year,
        bpm: metadata.bpm,
        comment: metadata.comment.clone(),
        lyrics: metadata.lyrics.clone(),
        lyrics_kind: metadata.lyrics_kind.clone(),
        tag_rating: metadata.tag_rating,
        tag_rating_scale: metadata.tag_rating_scale,
    }
}

fn stable_shadow_segment(value: &str) -> String {
    format!("{:x}", Sha384::digest(value.as_bytes()))
}

const TRACK_METADATA_FIELDS: &[(&str, &str, &str, &str)] = &[
    ("title", "Title", "track", "string"),
    ("sort_title", "Sort title", "track", "string"),
    ("subtitle", "Subtitle / version", "track", "string"),
    ("album", "Album", "album", "string"),
    ("track_artists", "Artists", "credits", "string_list"),
    ("album_artists", "Album artists", "album", "string_list"),
    ("composers", "Composers", "credits", "string_list"),
    ("lyricists", "Lyricists", "credits", "string_list"),
    ("genres", "Genres", "classification", "string_list"),
    ("disc_number", "Disc number", "album", "integer"),
    ("disc_total", "Total discs", "album", "integer"),
    ("track_number", "Track number", "track", "integer"),
    ("track_total", "Total tracks", "album", "integer"),
    ("date", "Release date", "album", "string"),
    ("year", "Year", "album", "integer"),
    ("bpm", "BPM", "track", "integer"),
    ("comment", "Comment", "track", "string"),
];

async fn track_id_for_file(pool: &DbPool, file_id: i64) -> Result<Option<i64>> {
    Ok(
        sqlx::query_scalar("SELECT id FROM tracks WHERE file_id = ?1")
            .bind(file_id)
            .fetch_optional(pool)
            .await?,
    )
}

async fn save_track_metadata_source(
    pool: &DbPool,
    file_id: i64,
    track: &TrackIngest,
) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    let data = serde_json::to_string(track)?;
    sqlx::query(
        r#"
        INSERT INTO track_metadata_sources (file_id, source_kind, data_json, captured_at)
        VALUES (?1, 'file', ?2, ?3)
        ON CONFLICT(file_id) DO UPDATE SET
            source_kind = 'file',
            data_json = excluded.data_json,
            captured_at = excluded.captured_at
        "#,
    )
    .bind(file_id)
    .bind(data)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(())
}

async fn load_track_metadata_source(pool: &DbPool, file_id: i64) -> Result<Option<TrackIngest>> {
    let source: Option<String> =
        sqlx::query_scalar("SELECT data_json FROM track_metadata_sources WHERE file_id = ?1")
            .bind(file_id)
            .fetch_optional(pool)
            .await?;
    source
        .map(|source| serde_json::from_str(&source).context("invalid metadata source snapshot"))
        .transpose()
}

async fn load_track_metadata_overrides(
    pool: &DbPool,
    track_id: i64,
) -> Result<HashMap<String, Value>> {
    let rows = sqlx::query(
        "SELECT field_key, value_json FROM track_metadata_overrides WHERE track_id = ?1",
    )
    .bind(track_id)
    .fetch_all(pool)
    .await?;
    let mut values = HashMap::with_capacity(rows.len());
    for row in rows {
        let key: String = row.try_get("field_key")?;
        let value: String = row.try_get("value_json")?;
        values.insert(
            key,
            serde_json::from_str(&value).context("invalid metadata override value")?,
        );
    }
    Ok(values)
}

fn is_supported_metadata_field(key: &str) -> bool {
    TRACK_METADATA_FIELDS
        .iter()
        .any(|(candidate, _, _, _)| candidate == &key)
}

fn normalize_metadata_value(key: &str, value: &Value) -> Result<Value> {
    let value = match key {
        "title" => {
            let title = value
                .as_str()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .context("title cannot be empty")?;
            Value::String(title.to_string())
        }
        "sort_title" | "subtitle" | "album" | "date" | "comment" => match value {
            Value::Null => Value::Null,
            Value::String(value) => {
                let value = value.trim();
                if value.is_empty() {
                    Value::Null
                } else {
                    Value::String(value.to_string())
                }
            }
            _ => bail!("{key} must be a string or null"),
        },
        "track_artists" | "album_artists" | "composers" | "lyricists" | "genres" => {
            let raw_values = match value {
                Value::Array(values) => values
                    .iter()
                    .map(|value| {
                        value
                            .as_str()
                            .map(ToOwned::to_owned)
                            .with_context(|| format!("{key} must contain only strings"))
                    })
                    .collect::<Result<Vec<_>>>()?,
                Value::String(value) => value
                    .split([';', '\n'])
                    .map(ToOwned::to_owned)
                    .collect::<Vec<_>>(),
                Value::Null => Vec::new(),
                _ => bail!("{key} must be a string list"),
            };
            let mut values = Vec::new();
            for value in raw_values {
                let value = value.trim();
                if value.is_empty()
                    || values
                        .iter()
                        .any(|existing: &String| existing.eq_ignore_ascii_case(value))
                {
                    continue;
                }
                values.push(value.to_string());
            }
            serde_json::to_value(values)?
        }
        "disc_number" | "disc_total" | "track_number" | "track_total" | "year" | "bpm" => {
            if value.is_null() {
                Value::Null
            } else {
                let number = value
                    .as_i64()
                    .or_else(|| value.as_str().and_then(|value| value.trim().parse().ok()))
                    .with_context(|| format!("{key} must be an integer or null"))?;
                if number < 0 {
                    bail!("{key} cannot be negative");
                }
                if key == "year" && number > 9999 {
                    bail!("year must be between 0 and 9999");
                }
                if key == "bpm" && number > 999 {
                    bail!("BPM must be between 0 and 999");
                }
                Value::Number(number.into())
            }
        }
        _ => bail!("unsupported metadata field: {key}"),
    };
    Ok(value)
}

fn metadata_field_value(track: &TrackIngest, key: &str) -> Value {
    match key {
        "title" => Value::String(track.title.clone()),
        "sort_title" => serde_json::to_value(&track.sort_title).unwrap_or(Value::Null),
        "subtitle" => serde_json::to_value(&track.subtitle).unwrap_or(Value::Null),
        "album" => serde_json::to_value(&track.album).unwrap_or(Value::Null),
        "track_artists" => serde_json::to_value(&track.track_artists).unwrap_or(Value::Null),
        "album_artists" => serde_json::to_value(&track.album_artists).unwrap_or(Value::Null),
        "composers" => serde_json::to_value(&track.composers).unwrap_or(Value::Null),
        "lyricists" => serde_json::to_value(&track.lyricists).unwrap_or(Value::Null),
        "genres" => serde_json::to_value(&track.genres).unwrap_or(Value::Null),
        "disc_number" => serde_json::to_value(track.disc_number).unwrap_or(Value::Null),
        "disc_total" => serde_json::to_value(track.disc_total).unwrap_or(Value::Null),
        "track_number" => serde_json::to_value(track.track_number).unwrap_or(Value::Null),
        "track_total" => serde_json::to_value(track.track_total).unwrap_or(Value::Null),
        "date" => serde_json::to_value(&track.date).unwrap_or(Value::Null),
        "year" => serde_json::to_value(track.year).unwrap_or(Value::Null),
        "bpm" => serde_json::to_value(track.bpm).unwrap_or(Value::Null),
        "comment" => serde_json::to_value(&track.comment).unwrap_or(Value::Null),
        _ => Value::Null,
    }
}

fn apply_metadata_overrides(
    track: &mut TrackIngest,
    overrides: &HashMap<String, Value>,
) -> Result<()> {
    for (key, value) in overrides {
        let value = normalize_metadata_value(key, value)?;
        match key.as_str() {
            "title" => track.title = value.as_str().unwrap_or_default().to_string(),
            "sort_title" => track.sort_title = value.as_str().map(ToOwned::to_owned),
            "subtitle" => track.subtitle = value.as_str().map(ToOwned::to_owned),
            "album" => track.album = value.as_str().map(ToOwned::to_owned),
            "track_artists" => track.track_artists = serde_json::from_value(value)?,
            "album_artists" => track.album_artists = serde_json::from_value(value)?,
            "composers" => track.composers = serde_json::from_value(value)?,
            "lyricists" => track.lyricists = serde_json::from_value(value)?,
            "genres" => track.genres = serde_json::from_value(value)?,
            "disc_number" => track.disc_number = value.as_i64(),
            "disc_total" => track.disc_total = value.as_i64(),
            "track_number" => track.track_number = value.as_i64(),
            "track_total" => track.track_total = value.as_i64(),
            "date" => track.date = value.as_str().map(ToOwned::to_owned),
            "year" => track.year = value.as_i64(),
            "bpm" => track.bpm = value.as_i64(),
            "comment" => track.comment = value.as_str().map(ToOwned::to_owned),
            _ => bail!("unsupported metadata field: {key}"),
        }
    }
    Ok(())
}

async fn upsert_track(
    pool: &DbPool,
    file_id: i64,
    library_root_id: i64,
    track: &TrackIngest,
) -> Result<i64> {
    let now = Utc::now().to_rfc3339();
    let album_id = if let Some(album_title) = &track.album {
        let album_artists = if track.album_artists.is_empty() {
            if track.track_artists.is_empty() {
                vec!["Unknown Artist".to_string()]
            } else {
                track.track_artists.clone()
            }
        } else {
            track.album_artists.clone()
        };
        let album_artist_display = album_artists.join("; ");
        let album_key = album_key(
            &album_artist_display,
            album_title,
            track.year,
            library_root_id,
        );
        let normalized_title = normalize_text(album_title);

        sqlx::query(
            r#"
            INSERT INTO albums (
                title, normalized_title, album_key, album_artist_display, date, year, total_discs, created_at, updated_at
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)
            ON CONFLICT(album_key) DO UPDATE SET
                title = excluded.title,
                normalized_title = excluded.normalized_title,
                album_artist_display = excluded.album_artist_display,
                date = excluded.date,
                year = excluded.year,
                total_discs = excluded.total_discs,
                updated_at = excluded.updated_at
            "#,
        )
        .bind(album_title)
        .bind(&normalized_title)
        .bind(&album_key)
        .bind(&album_artist_display)
        .bind(&track.date)
        .bind(track.year)
        .bind(track.disc_total)
        .bind(&now)
        .execute(pool)
        .await?;

        let album_id: i64 = sqlx::query("SELECT id FROM albums WHERE album_key = ?1")
            .bind(&album_key)
            .fetch_one(pool)
            .await?
            .try_get("id")?;

        sqlx::query("DELETE FROM album_artists WHERE album_id = ?1")
            .bind(album_id)
            .execute(pool)
            .await?;
        for (position, artist_name) in album_artists.iter().enumerate() {
            let artist_id = upsert_artist(pool, artist_name).await?;
            sqlx::query(
                "INSERT OR IGNORE INTO album_artists (album_id, artist_id, position) VALUES (?1, ?2, ?3)",
            )
            .bind(album_id)
            .bind(artist_id)
            .bind(position as i64)
            .execute(pool)
            .await?;
        }

        Some(album_id)
    } else {
        None
    };

    sqlx::query(
        r#"
        INSERT INTO tracks (
            file_id, album_id, title, sort_title, subtitle, disc_number, disc_total,
            track_number, track_total, duration_ms, date, year, bpm, comment,
            tag_rating, tag_rating_scale, created_at, updated_at
        )
        VALUES (
            ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
            ?14, ?15, ?16, ?17, ?17
        )
        ON CONFLICT(file_id) DO UPDATE SET
            album_id = excluded.album_id,
            title = excluded.title,
            sort_title = excluded.sort_title,
            subtitle = excluded.subtitle,
            disc_number = excluded.disc_number,
            disc_total = excluded.disc_total,
            track_number = excluded.track_number,
            track_total = excluded.track_total,
            duration_ms = excluded.duration_ms,
            date = excluded.date,
            year = excluded.year,
            bpm = excluded.bpm,
            comment = excluded.comment,
            tag_rating = excluded.tag_rating,
            tag_rating_scale = excluded.tag_rating_scale,
            updated_at = excluded.updated_at
        "#,
    )
    .bind(file_id)
    .bind(album_id)
    .bind(&track.title)
    .bind(&track.sort_title)
    .bind(&track.subtitle)
    .bind(track.disc_number)
    .bind(track.disc_total)
    .bind(track.track_number)
    .bind(track.track_total)
    .bind(track.duration_ms)
    .bind(&track.date)
    .bind(track.year)
    .bind(track.bpm)
    .bind(&track.comment)
    .bind(track.tag_rating)
    .bind(track.tag_rating_scale)
    .bind(&now)
    .execute(pool)
    .await?;

    let track_id: i64 = sqlx::query("SELECT id FROM tracks WHERE file_id = ?1")
        .bind(file_id)
        .fetch_one(pool)
        .await?
        .try_get("id")?;

    sqlx::query("DELETE FROM track_artists WHERE track_id = ?1")
        .bind(track_id)
        .execute(pool)
        .await?;
    let track_artists = if track.track_artists.is_empty() {
        vec!["Unknown Artist".to_string()]
    } else {
        track.track_artists.clone()
    };
    insert_track_artist_role(pool, track_id, "primary", &track_artists).await?;
    insert_track_artist_role(pool, track_id, "composer", &track.composers).await?;
    insert_track_artist_role(pool, track_id, "lyricist", &track.lyricists).await?;

    sqlx::query("DELETE FROM track_genres WHERE track_id = ?1")
        .bind(track_id)
        .execute(pool)
        .await?;
    for genre in &track.genres {
        let genre_id = upsert_genre(pool, genre).await?;
        sqlx::query("INSERT OR IGNORE INTO track_genres (track_id, genre_id) VALUES (?1, ?2)")
            .bind(track_id)
            .bind(genre_id)
            .execute(pool)
            .await?;
    }

    if let Some(lyrics) = track
        .lyrics
        .as_ref()
        .filter(|lyrics| !lyrics.trim().is_empty())
    {
        let lyrics_kind = track
            .lyrics_kind
            .as_deref()
            .filter(|kind| !kind.trim().is_empty())
            .unwrap_or("text");
        sqlx::query(
            r#"
            INSERT INTO lyrics (
                track_id, kind, text, source, is_locked, created_at, updated_at
            )
            VALUES (?1, ?2, ?3, 'file', 0, ?4, ?4)
            ON CONFLICT(track_id) DO UPDATE SET
                kind = excluded.kind,
                text = excluded.text,
                parsed_json = NULL,
                language = NULL,
                translation_text = NULL,
                pronunciation_text = NULL,
                offset_ms = 0,
                source = 'file',
                updated_at = excluded.updated_at
            WHERE lyrics.is_locked = 0
            "#,
        )
        .bind(track_id)
        .bind(lyrics_kind)
        .bind(lyrics)
        .bind(&now)
        .execute(pool)
        .await?;
    } else {
        sqlx::query("DELETE FROM lyrics WHERE track_id = ?1 AND is_locked = 0")
            .bind(track_id)
            .execute(pool)
            .await?;
    }

    rebuild_track_search_row(pool, track_id).await?;
    Ok(track_id)
}

async fn ensure_track_media_graph(
    pool: &DbPool,
    track_id: i64,
    file_id: i64,
    file: &FileIngest,
    track: &TrackIngest,
) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    let release_id = ensure_release_edition_for_track(pool, track_id, &now).await?;
    let existing = sqlx::query(
        r#"
        SELECT
            links.release_track_id,
            links.match_kind,
            rt.recording_id,
            recording.work_id,
            (
                SELECT master.id
                FROM release_track_media_variants relation
                JOIN media_variants variant ON variant.id = relation.media_variant_id
                JOIN audio_masters master ON master.id = variant.audio_master_id
                WHERE relation.release_track_id = rt.id
                ORDER BY relation.is_preferred DESC, variant.id
                LIMIT 1
            ) AS audio_master_id,
            (
                SELECT replica.media_variant_id
                FROM media_replicas replica
                WHERE replica.file_id = ?2
                LIMIT 1
            ) AS media_variant_id
        FROM legacy_track_catalog_links links
        JOIN release_tracks rt ON rt.id = links.release_track_id
        JOIN catalog_recordings recording ON recording.id = rt.recording_id
        WHERE links.track_id = ?1
        "#,
    )
    .bind(track_id)
    .bind(file_id)
    .fetch_optional(pool)
    .await?;

    let recording_kind = inferred_recording_kind(track.subtitle.as_deref());
    let mastering_kind = inferred_mastering_kind(track.subtitle.as_deref());
    let master_label = track
        .subtitle
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("Library source");

    if let Some(existing) = existing {
        let release_track_id: i64 = existing.try_get("release_track_id")?;
        let match_kind: String = existing.try_get("match_kind")?;
        let recording_id: i64 = existing.try_get("recording_id")?;
        let work_id: i64 = existing.try_get("work_id")?;
        let audio_master_id: Option<i64> = existing.try_get("audio_master_id")?;
        let media_variant_id: Option<i64> = existing.try_get("media_variant_id")?;

        // A file-seeded recording belongs to this release track, so tag edits may
        // update it. Once several releases are explicitly linked to a confirmed
        // recording, rescanning one release must not rewrite their shared identity.
        if match_kind != "confirmed_recording" {
            sqlx::query(
                "UPDATE catalog_works SET title = ?1, normalized_title = ?2, updated_at = ?3 WHERE id = ?4",
            )
            .bind(&track.title)
            .bind(normalize_text(&track.title))
            .bind(&now)
            .bind(work_id)
            .execute(pool)
            .await?;
            sqlx::query(
                r#"
                UPDATE catalog_recordings
                SET title = ?1, version_title = ?2, recording_kind = ?3,
                    duration_ms = ?4, updated_at = ?5
                WHERE id = ?6
                "#,
            )
            .bind(&track.title)
            .bind(&track.subtitle)
            .bind(recording_kind)
            .bind(track.duration_ms)
            .bind(&now)
            .bind(recording_id)
            .execute(pool)
            .await?;
        }
        sqlx::query(
            r#"
            UPDATE release_tracks
            SET release_id = ?1, title = ?2, disc_number = ?3,
                track_number = ?4, duration_ms = ?5, updated_at = ?6
            WHERE id = ?7
            "#,
        )
        .bind(release_id)
        .bind(&track.title)
        .bind(track.disc_number)
        .bind(track.track_number)
        .bind(track.duration_ms)
        .bind(&now)
        .bind(release_track_id)
        .execute(pool)
        .await?;
        if let Some(audio_master_id) = audio_master_id {
            sqlx::query(
                r#"
                UPDATE audio_masters
                SET label = ?1, mastering_kind = ?2, release_year = ?3, updated_at = ?4
                WHERE id = ?5
                "#,
            )
            .bind(master_label)
            .bind(mastering_kind)
            .bind(track.year)
            .bind(&now)
            .bind(audio_master_id)
            .execute(pool)
            .await?;
        }
        if let Some(media_variant_id) = media_variant_id {
            update_media_variant(pool, media_variant_id, file, track.duration_ms, &now).await?;
            sqlx::query(
                r#"
                UPDATE media_replicas
                SET library_root_id = ?1, availability_state = 'ready',
                    last_verified_at = ?2, updated_at = ?2
                WHERE file_id = ?3
                "#,
            )
            .bind(file.library_root_id)
            .bind(&now)
            .bind(file_id)
            .execute(pool)
            .await?;
        }
        return Ok(());
    }

    let work_id: i64 = sqlx::query_scalar(
        r#"
        INSERT INTO catalog_works (
            global_id, title, normalized_title, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?4)
        RETURNING id
        "#,
    )
    .bind(Uuid::now_v7().to_string())
    .bind(&track.title)
    .bind(normalize_text(&track.title))
    .bind(&now)
    .fetch_one(pool)
    .await?;
    let recording_id: i64 = sqlx::query_scalar(
        r#"
        INSERT INTO catalog_recordings (
            global_id, work_id, title, version_title, recording_kind,
            duration_ms, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)
        RETURNING id
        "#,
    )
    .bind(Uuid::now_v7().to_string())
    .bind(work_id)
    .bind(&track.title)
    .bind(&track.subtitle)
    .bind(recording_kind)
    .bind(track.duration_ms)
    .bind(&now)
    .fetch_one(pool)
    .await?;
    let release_track_id: i64 = sqlx::query_scalar(
        r#"
        INSERT INTO release_tracks (
            global_id, release_id, recording_id, title, disc_number,
            track_number, duration_ms, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)
        RETURNING id
        "#,
    )
    .bind(Uuid::now_v7().to_string())
    .bind(release_id)
    .bind(recording_id)
    .bind(&track.title)
    .bind(track.disc_number)
    .bind(track.track_number)
    .bind(track.duration_ms)
    .bind(&now)
    .fetch_one(pool)
    .await?;
    sqlx::query(
        r#"
        INSERT INTO legacy_track_catalog_links (
            track_id, release_track_id, match_kind, match_confidence,
            created_at, updated_at
        )
        VALUES (?1, ?2, 'file_seeded', 1.0, ?3, ?3)
        "#,
    )
    .bind(track_id)
    .bind(release_track_id)
    .bind(&now)
    .execute(pool)
    .await?;

    let audio_master_id: i64 = sqlx::query_scalar(
        r#"
        INSERT INTO audio_masters (
            global_id, recording_id, label, mastering_kind, release_year,
            created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)
        RETURNING id
        "#,
    )
    .bind(Uuid::now_v7().to_string())
    .bind(recording_id)
    .bind(master_label)
    .bind(mastering_kind)
    .bind(track.year)
    .bind(&now)
    .fetch_one(pool)
    .await?;
    let media_variant_id: i64 = sqlx::query_scalar(
        r#"
        INSERT INTO media_variants (
            global_id, audio_master_id, variant_key, codec, container,
            bitrate, sample_rate, bit_depth, channels, duration_ms,
            quick_hash, created_at, updated_at
        )
        VALUES (
            ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?12
        )
        RETURNING id
        "#,
    )
    .bind(Uuid::now_v7().to_string())
    .bind(audio_master_id)
    .bind(format!("file:{file_id}"))
    .bind(&file.codec)
    .bind(&file.extension)
    .bind(file.bitrate)
    .bind(file.sample_rate)
    .bind(file.bit_depth)
    .bind(file.channels)
    .bind(file.duration_ms.or(track.duration_ms))
    .bind(&file.quick_hash)
    .bind(&now)
    .fetch_one(pool)
    .await?;
    sqlx::query(
        r#"
        INSERT INTO release_track_media_variants (
            release_track_id, media_variant_id, relation_kind, is_preferred, created_at
        )
        VALUES (?1, ?2, 'exact', 1, ?3)
        "#,
    )
    .bind(release_track_id)
    .bind(media_variant_id)
    .bind(&now)
    .execute(pool)
    .await?;
    sqlx::query(
        r#"
        INSERT INTO media_replicas (
            media_variant_id, file_id, library_root_id, source_kind,
            availability_state, is_primary, last_verified_at, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, 'core', 'ready', 1, ?4, ?4, ?4)
        "#,
    )
    .bind(media_variant_id)
    .bind(file_id)
    .bind(file.library_root_id)
    .bind(&now)
    .execute(pool)
    .await?;
    Ok(())
}

async fn ensure_release_edition_for_track(
    pool: &DbPool,
    track_id: i64,
    now: &str,
) -> Result<Option<i64>> {
    let album = sqlx::query(
        r#"
        SELECT al.id, al.title
        FROM tracks t
        JOIN albums al ON al.id = t.album_id
        WHERE t.id = ?1
        "#,
    )
    .bind(track_id)
    .fetch_optional(pool)
    .await?;
    let Some(album) = album else {
        return Ok(None);
    };
    let album_id: i64 = album.try_get("id")?;
    let title: String = album.try_get("title")?;
    sqlx::query(
        r#"
        INSERT INTO release_editions (
            global_id, album_id, edition_title, edition_kind, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, 'album', ?4, ?4)
        ON CONFLICT(album_id) DO UPDATE SET
            edition_title = excluded.edition_title,
            updated_at = excluded.updated_at
        "#,
    )
    .bind(Uuid::now_v7().to_string())
    .bind(album_id)
    .bind(title)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(Some(
        sqlx::query_scalar("SELECT id FROM release_editions WHERE album_id = ?1")
            .bind(album_id)
            .fetch_one(pool)
            .await?,
    ))
}

async fn update_media_variant(
    pool: &DbPool,
    media_variant_id: i64,
    file: &FileIngest,
    track_duration_ms: Option<i64>,
    now: &str,
) -> Result<()> {
    sqlx::query(
        r#"
        UPDATE media_variants
        SET codec = ?1, container = ?2, bitrate = ?3, sample_rate = ?4,
            bit_depth = ?5, channels = ?6, duration_ms = ?7,
            quick_hash = ?8, updated_at = ?9
        WHERE id = ?10
        "#,
    )
    .bind(&file.codec)
    .bind(&file.extension)
    .bind(file.bitrate)
    .bind(file.sample_rate)
    .bind(file.bit_depth)
    .bind(file.channels)
    .bind(file.duration_ms.or(track_duration_ms))
    .bind(&file.quick_hash)
    .bind(now)
    .bind(media_variant_id)
    .execute(pool)
    .await?;
    Ok(())
}

async fn file_ingest_by_id(pool: &DbPool, file_id: i64) -> Result<FileIngest> {
    let row = sqlx::query(
        r#"
        SELECT
            library_root_id, path, relative_path, extension, size_bytes,
            modified_at, quick_hash, scan_status, scan_message, codec,
            sample_rate, channels, duration_ms, bitrate, bit_depth
        FROM files
        WHERE id = ?1
        "#,
    )
    .bind(file_id)
    .fetch_one(pool)
    .await?;
    Ok(FileIngest {
        library_root_id: row.try_get("library_root_id")?,
        path: row.try_get("path")?,
        relative_path: row.try_get("relative_path")?,
        extension: row.try_get("extension")?,
        size_bytes: row.try_get("size_bytes")?,
        modified_at: row.try_get("modified_at")?,
        quick_hash: row.try_get("quick_hash")?,
        scan_status: row.try_get("scan_status")?,
        scan_message: row.try_get("scan_message")?,
        codec: row.try_get("codec")?,
        sample_rate: row.try_get("sample_rate")?,
        channels: row.try_get("channels")?,
        duration_ms: row.try_get("duration_ms")?,
        bitrate: row.try_get("bitrate")?,
        bit_depth: row.try_get("bit_depth")?,
    })
}

fn inferred_recording_kind(subtitle: Option<&str>) -> &'static str {
    let subtitle = subtitle.unwrap_or_default().to_ascii_lowercase();
    if subtitle.contains("live") || subtitle.contains("现场") {
        "live"
    } else if subtitle.contains("acoustic") || subtitle.contains("不插电") {
        "acoustic"
    } else if subtitle.contains("demo") {
        "demo"
    } else {
        "studio"
    }
}

fn inferred_mastering_kind(subtitle: Option<&str>) -> &'static str {
    let subtitle = subtitle.unwrap_or_default().to_ascii_lowercase();
    if subtitle.contains("remaster") || subtitle.contains("重制") {
        "remaster"
    } else if subtitle.contains("remix") {
        "remix"
    } else {
        "unknown"
    }
}

async fn upsert_artist(pool: &DbPool, name: &str) -> Result<i64> {
    let normalized = normalize_text(name);
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT INTO artists (name, normalized_name, created_at, updated_at)
        VALUES (?1, ?2, ?3, ?3)
        ON CONFLICT(normalized_name) DO UPDATE SET name = excluded.name, updated_at = excluded.updated_at
        "#,
    )
    .bind(name)
    .bind(&normalized)
    .bind(&now)
    .execute(pool)
    .await?;

    Ok(
        sqlx::query("SELECT id FROM artists WHERE normalized_name = ?1")
            .bind(&normalized)
            .fetch_one(pool)
            .await?
            .try_get("id")?,
    )
}

async fn insert_track_artist_role(
    pool: &DbPool,
    track_id: i64,
    role: &str,
    artists: &[String],
) -> Result<()> {
    for (position, artist_name) in artists.iter().enumerate() {
        let artist_id = upsert_artist(pool, artist_name).await?;
        sqlx::query(
            "INSERT OR IGNORE INTO track_artists (track_id, artist_id, role, position) VALUES (?1, ?2, ?3, ?4)",
        )
        .bind(track_id)
        .bind(artist_id)
        .bind(role)
        .bind(position as i64)
        .execute(pool)
        .await?;
    }
    Ok(())
}

async fn upsert_genre(pool: &DbPool, name: &str) -> Result<i64> {
    let normalized = normalize_text(name);
    sqlx::query("INSERT OR IGNORE INTO genres (name, normalized_name) VALUES (?1, ?2)")
        .bind(name)
        .bind(&normalized)
        .execute(pool)
        .await?;

    Ok(
        sqlx::query("SELECT id FROM genres WHERE normalized_name = ?1")
            .bind(&normalized)
            .fetch_one(pool)
            .await?
            .try_get("id")?,
    )
}

async fn rebuild_track_search_row(pool: &DbPool, track_id: i64) -> Result<()> {
    let row = sqlx::query(
        r#"
        SELECT
            t.title AS title,
            COALESCE(al.title, '') AS album,
            COALESCE(GROUP_CONCAT(DISTINCT ar.name), '') AS artist,
            COALESCE(GROUP_CONCAT(DISTINCT g.name), '') AS genre,
            COALESCE(l.text, '') AS lyrics
        FROM tracks t
        LEFT JOIN albums al ON al.id = t.album_id
        LEFT JOIN track_artists ta ON ta.track_id = t.id AND ta.role = 'primary'
        LEFT JOIN artists ar ON ar.id = ta.artist_id
        LEFT JOIN track_genres tg ON tg.track_id = t.id
        LEFT JOIN genres g ON g.id = tg.genre_id
        LEFT JOIN lyrics l ON l.track_id = t.id
        WHERE t.id = ?1
        GROUP BY t.id
        "#,
    )
    .bind(track_id)
    .fetch_one(pool)
    .await?;

    sqlx::query("DELETE FROM search_fts WHERE track_id = ?1")
        .bind(track_id)
        .execute(pool)
        .await?;
    sqlx::query(
        "INSERT INTO search_fts (track_id, title, album, artist, genre, lyrics) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    )
    .bind(track_id)
    .bind(row.try_get::<String, _>("title")?)
    .bind(row.try_get::<String, _>("album")?)
    .bind(row.try_get::<String, _>("artist")?)
    .bind(row.try_get::<String, _>("genre")?)
    .bind(row.try_get::<String, _>("lyrics")?)
    .execute(pool)
    .await?;

    Ok(())
}

pub async fn list_albums(pool: &DbPool, limit: u32, offset: u32) -> Result<Vec<AlbumSummary>> {
    let rows = sqlx::query(
        r#"
        SELECT al.id, al.title, al.album_artist_display, al.date, al.year, al.total_discs,
               al.cover_asset_id, COUNT(t.id) AS track_count
        FROM albums al
        LEFT JOIN tracks t ON t.album_id = al.id
        GROUP BY al.id
        ORDER BY COALESCE(al.sort_title, al.title) COLLATE NOCASE
        LIMIT ?1 OFFSET ?2
        "#,
    )
    .bind(limit as i64)
    .bind(offset as i64)
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_album).collect()
}

pub async fn list_artists(pool: &DbPool, limit: u32, offset: u32) -> Result<Vec<ArtistSummary>> {
    let rows = sqlx::query(
        r#"
        SELECT ar.id,
               COALESCE(NULLIF(ap.display_name, ''), ar.name) AS name,
               COALESCE(NULLIF(ap.sort_name, ''), ar.sort_name) AS sort_name,
               COUNT(DISTINCT ta.track_id) AS track_count,
               COUNT(DISTINCT aa.album_id) AS album_count,
               COALESCE((SELECT MAX(av.revision)
                         FROM artist_visuals av
                         WHERE av.artist_id = ar.id), 0) AS artwork_revision,
               EXISTS(SELECT 1
                      FROM artist_assets ai
                      WHERE ai.artist_id = ar.id AND ai.deleted_at IS NULL) AS has_artwork
        FROM artists ar
        LEFT JOIN artist_profiles ap ON ap.artist_id = ar.id
        LEFT JOIN track_artists ta ON ta.artist_id = ar.id
        LEFT JOIN album_artists aa ON aa.artist_id = ar.id
        GROUP BY ar.id
        ORDER BY COALESCE(NULLIF(ap.sort_name, ''), ar.sort_name,
                          NULLIF(ap.display_name, ''), ar.name) COLLATE NOCASE
        LIMIT ?1 OFFSET ?2
        "#,
    )
    .bind(limit as i64)
    .bind(offset as i64)
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_artist).collect()
}

pub async fn artist_detail(pool: &DbPool, artist_id: i64) -> Result<ArtistDetail> {
    let artist_row = sqlx::query(
        r#"
        SELECT ar.id,
               COALESCE(NULLIF(ap.display_name, ''), ar.name) AS name,
               COALESCE(NULLIF(ap.sort_name, ''), ar.sort_name) AS sort_name,
               COUNT(DISTINCT ta.track_id) AS track_count,
               COUNT(DISTINCT aa.album_id) AS album_count,
               COALESCE((SELECT MAX(av.revision)
                         FROM artist_visuals av
                         WHERE av.artist_id = ar.id), 0) AS artwork_revision,
               EXISTS(SELECT 1
                      FROM artist_assets ai
                      WHERE ai.artist_id = ar.id AND ai.deleted_at IS NULL) AS has_artwork
        FROM artists ar
        LEFT JOIN artist_profiles ap ON ap.artist_id = ar.id
        LEFT JOIN track_artists ta ON ta.artist_id = ar.id
        LEFT JOIN album_artists aa ON aa.artist_id = ar.id
        WHERE ar.id = ?1
        GROUP BY ar.id
        "#,
    )
    .bind(artist_id)
    .fetch_one(pool)
    .await?;

    let album_rows = sqlx::query(
        r#"
        SELECT al.id, al.title, al.album_artist_display, al.date, al.year, al.total_discs,
               al.cover_asset_id, COUNT(DISTINCT t.id) AS track_count
        FROM albums al
        LEFT JOIN tracks t ON t.album_id = al.id
        LEFT JOIN album_artists aa ON aa.album_id = al.id
        LEFT JOIN track_artists ta ON ta.track_id = t.id
        WHERE aa.artist_id = ?1 OR ta.artist_id = ?1
        GROUP BY al.id
        ORDER BY COALESCE(al.year, 0) DESC, al.title COLLATE NOCASE
        "#,
    )
    .bind(artist_id)
    .fetch_all(pool)
    .await?;

    let track_rows = sqlx::query(
        track_select_sql(
            r#"
            WHERE EXISTS (
                SELECT 1
                FROM track_artists ta2
                WHERE ta2.track_id = t.id AND ta2.artist_id = ?1
            )
            GROUP BY t.id
            ORDER BY t.title COLLATE NOCASE
            "#,
        )
        .as_str(),
    )
    .bind(artist_id)
    .fetch_all(pool)
    .await?;

    Ok(ArtistDetail {
        artist: row_to_artist(artist_row)?,
        profile: artist_profile(pool, artist_id).await?,
        assets: list_artist_assets(pool, artist_id).await?,
        visuals: list_artist_visuals(pool, artist_id).await?,
        albums: album_rows
            .into_iter()
            .map(row_to_album)
            .collect::<Result<_>>()?,
        tracks: track_rows
            .into_iter()
            .map(row_to_track)
            .collect::<Result<_>>()?,
    })
}

pub async fn artist_profile(pool: &DbPool, artist_id: i64) -> Result<ArtistProfile> {
    let row = sqlx::query(
        r#"
        SELECT display_name, sort_name, musicbrainz_id, artist_type, country,
               begin_date, end_date, disambiguation, biography, aliases_json,
               genres_json, links_json, updated_at
        FROM artist_profiles
        WHERE artist_id = ?1
        "#,
    )
    .bind(artist_id)
    .fetch_optional(pool)
    .await?;
    let Some(row) = row else {
        return Ok(ArtistProfile::default());
    };
    Ok(ArtistProfile {
        display_name: row.try_get("display_name")?,
        sort_name: row.try_get("sort_name")?,
        musicbrainz_id: row.try_get("musicbrainz_id")?,
        artist_type: row.try_get("artist_type")?,
        country: row.try_get("country")?,
        begin_date: row.try_get("begin_date")?,
        end_date: row.try_get("end_date")?,
        disambiguation: row.try_get("disambiguation")?,
        biography: row.try_get("biography")?,
        aliases: serde_json::from_str(&row.try_get::<String, _>("aliases_json")?)
            .unwrap_or_default(),
        genres: serde_json::from_str(&row.try_get::<String, _>("genres_json")?).unwrap_or_default(),
        links: serde_json::from_str(&row.try_get::<String, _>("links_json")?).unwrap_or_default(),
        updated_at: Some(parse_datetime(row.try_get::<String, _>("updated_at")?)?),
    })
}

pub async fn update_artist_profile(
    pool: &DbPool,
    artist_id: i64,
    update: &UpdateArtistProfile,
) -> Result<ArtistProfile> {
    let exists: Option<i64> = sqlx::query_scalar("SELECT id FROM artists WHERE id = ?1")
        .bind(artist_id)
        .fetch_optional(pool)
        .await?;
    anyhow::ensure!(exists.is_some(), "artist {artist_id} was not found");

    let now = Utc::now().to_rfc3339();
    let aliases_json = serde_json::to_string(&update.aliases)?;
    let genres_json = serde_json::to_string(&update.genres)?;
    let links_json = serde_json::to_string(&update.links)?;
    sqlx::query(
        r#"
        INSERT INTO artist_profiles (
            artist_id, display_name, sort_name, musicbrainz_id, artist_type,
            country, begin_date, end_date, disambiguation, biography,
            aliases_json, genres_json, links_json, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?14)
        ON CONFLICT(artist_id) DO UPDATE SET
            display_name = excluded.display_name,
            sort_name = excluded.sort_name,
            musicbrainz_id = excluded.musicbrainz_id,
            artist_type = excluded.artist_type,
            country = excluded.country,
            begin_date = excluded.begin_date,
            end_date = excluded.end_date,
            disambiguation = excluded.disambiguation,
            biography = excluded.biography,
            aliases_json = excluded.aliases_json,
            genres_json = excluded.genres_json,
            links_json = excluded.links_json,
            updated_at = excluded.updated_at
        "#,
    )
    .bind(artist_id)
    .bind(trimmed_option(update.display_name.as_deref()))
    .bind(trimmed_option(update.sort_name.as_deref()))
    .bind(trimmed_option(update.musicbrainz_id.as_deref()))
    .bind(trimmed_option(update.artist_type.as_deref()))
    .bind(trimmed_option(update.country.as_deref()))
    .bind(trimmed_option(update.begin_date.as_deref()))
    .bind(trimmed_option(update.end_date.as_deref()))
    .bind(trimmed_option(update.disambiguation.as_deref()))
    .bind(trimmed_option(update.biography.as_deref()))
    .bind(aliases_json)
    .bind(genres_json)
    .bind(links_json)
    .bind(now)
    .execute(pool)
    .await?;
    artist_profile(pool, artist_id).await
}

fn trimmed_option(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

#[derive(Debug, Clone)]
pub struct NewArtistAsset<'a> {
    pub sha256: &'a str,
    pub original_filename: &'a str,
    pub storage_path: &'a str,
    pub mime_type: &'a str,
    pub width: u32,
    pub height: u32,
    pub byte_size: u64,
    pub photo_type: &'a str,
}

#[derive(Debug, Clone)]
pub struct ArtistAssetStorage {
    pub asset: ArtistAsset,
    pub storage_path: String,
}

#[derive(Debug, Clone)]
pub struct ArtistVisualSource {
    pub visual: ArtistVisual,
    pub assets: Vec<ArtistAssetStorage>,
}

pub async fn add_artist_asset(
    pool: &DbPool,
    artist_id: i64,
    asset: NewArtistAsset<'_>,
) -> Result<ArtistAsset> {
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT INTO artist_assets (
            artist_id, sha256, original_filename, storage_path, mime_type,
            width, height, byte_size, photo_type, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10)
        ON CONFLICT(artist_id, sha256) DO UPDATE SET
            original_filename = excluded.original_filename,
            storage_path = excluded.storage_path,
            mime_type = excluded.mime_type,
            width = excluded.width,
            height = excluded.height,
            byte_size = excluded.byte_size,
            deleted_at = NULL,
            updated_at = excluded.updated_at
        "#,
    )
    .bind(artist_id)
    .bind(asset.sha256)
    .bind(asset.original_filename)
    .bind(asset.storage_path)
    .bind(asset.mime_type)
    .bind(i64::from(asset.width))
    .bind(i64::from(asset.height))
    .bind(i64::try_from(asset.byte_size)?)
    .bind(asset.photo_type)
    .bind(now)
    .execute(pool)
    .await?;

    let id: i64 =
        sqlx::query_scalar("SELECT id FROM artist_assets WHERE artist_id = ?1 AND sha256 = ?2")
            .bind(artist_id)
            .bind(asset.sha256)
            .fetch_one(pool)
            .await?;
    artist_asset(pool, artist_id, id).await
}

pub async fn artist_asset(pool: &DbPool, artist_id: i64, id: i64) -> Result<ArtistAsset> {
    let row = sqlx::query(
        r#"
        SELECT id, artist_id, original_filename, mime_type, width, height,
               byte_size, photo_type, sort_order, created_at
        FROM artist_assets
        WHERE artist_id = ?1 AND id = ?2 AND deleted_at IS NULL
        "#,
    )
    .bind(artist_id)
    .bind(id)
    .fetch_one(pool)
    .await?;
    row_to_artist_asset(row)
}

pub async fn artist_asset_storage(
    pool: &DbPool,
    artist_id: i64,
    id: i64,
) -> Result<ArtistAssetStorage> {
    let row = sqlx::query(
        r#"
        SELECT id, artist_id, original_filename, storage_path, mime_type, width,
               height, byte_size, photo_type, sort_order, created_at
        FROM artist_assets
        WHERE artist_id = ?1 AND id = ?2 AND deleted_at IS NULL
        "#,
    )
    .bind(artist_id)
    .bind(id)
    .fetch_one(pool)
    .await?;
    let storage_path: String = row.try_get("storage_path")?;
    Ok(ArtistAssetStorage {
        asset: row_to_artist_asset(row)?,
        storage_path,
    })
}

pub async fn list_artist_assets(pool: &DbPool, artist_id: i64) -> Result<Vec<ArtistAsset>> {
    let rows = sqlx::query(
        r#"
        SELECT id, artist_id, original_filename, mime_type, width, height,
               byte_size, photo_type, sort_order, created_at
        FROM artist_assets
        WHERE artist_id = ?1 AND deleted_at IS NULL
        ORDER BY sort_order, id
        "#,
    )
    .bind(artist_id)
    .fetch_all(pool)
    .await?;
    rows.into_iter().map(row_to_artist_asset).collect()
}

pub async fn update_artist_asset(
    pool: &DbPool,
    artist_id: i64,
    id: i64,
    update: &UpdateArtistAsset,
) -> Result<ArtistAsset> {
    let current = artist_asset(pool, artist_id, id).await?;
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        UPDATE artist_assets
        SET photo_type = ?1, sort_order = ?2, updated_at = ?3
        WHERE artist_id = ?4 AND id = ?5 AND deleted_at IS NULL
        "#,
    )
    .bind(
        update
            .photo_type
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or(&current.photo_type),
    )
    .bind(update.sort_order.unwrap_or(current.sort_order))
    .bind(now)
    .bind(artist_id)
    .bind(id)
    .execute(pool)
    .await?;
    artist_asset(pool, artist_id, id).await
}

pub async fn delete_artist_asset(pool: &DbPool, artist_id: i64, id: i64) -> Result<()> {
    let mut transaction = pool.begin().await?;
    sqlx::query(
        r#"
        UPDATE artist_visuals
        SET asset_id = CASE WHEN asset_id = ?1 THEN NULL ELSE asset_id END,
            revision = revision + 1,
            updated_at = ?2
        WHERE artist_id = ?3 AND (
            asset_id = ?1 OR EXISTS (
                SELECT 1 FROM artist_visual_regions avr
                WHERE avr.artist_id = artist_visuals.artist_id
                  AND avr.slot = artist_visuals.slot
                  AND avr.asset_id = ?1
            )
        )
        "#,
    )
    .bind(id)
    .bind(Utc::now().to_rfc3339())
    .bind(artist_id)
    .execute(&mut *transaction)
    .await?;
    sqlx::query("DELETE FROM artist_visual_regions WHERE artist_id = ?1 AND asset_id = ?2")
        .bind(artist_id)
        .bind(id)
        .execute(&mut *transaction)
        .await?;
    sqlx::query("UPDATE artist_assets SET deleted_at = ?1 WHERE artist_id = ?2 AND id = ?3")
        .bind(Utc::now().to_rfc3339())
        .bind(artist_id)
        .bind(id)
        .execute(&mut *transaction)
        .await?;
    transaction.commit().await?;
    Ok(())
}

pub async fn list_artist_visuals(pool: &DbPool, artist_id: i64) -> Result<Vec<ArtistVisual>> {
    let rows = sqlx::query(
        r#"
        SELECT slot, asset_id, template, fit, focal_x, focal_y, blur,
               brightness, revision
        FROM artist_visuals
        WHERE artist_id = ?1
        ORDER BY slot
        "#,
    )
    .bind(artist_id)
    .fetch_all(pool)
    .await?;
    let mut visuals = Vec::with_capacity(rows.len());
    for row in rows {
        let slot: String = row.try_get("slot")?;
        visuals.push(ArtistVisual {
            asset_id: row.try_get("asset_id")?,
            template: row.try_get("template")?,
            fit: row.try_get("fit")?,
            focal_x: row.try_get::<f64, _>("focal_x")? as f32,
            focal_y: row.try_get::<f64, _>("focal_y")? as f32,
            blur: row.try_get::<f64, _>("blur")? as f32,
            brightness: row.try_get::<f64, _>("brightness")? as f32,
            revision: row.try_get("revision")?,
            regions: artist_visual_regions(pool, artist_id, &slot).await?,
            slot,
        });
    }
    Ok(visuals)
}

async fn artist_visual_regions(
    pool: &DbPool,
    artist_id: i64,
    slot: &str,
) -> Result<Vec<ArtistVisualRegion>> {
    let rows = sqlx::query(
        r#"
        SELECT position, asset_id, crop_x, crop_y, crop_width, crop_height,
               focal_x, focal_y
        FROM artist_visual_regions
        WHERE artist_id = ?1 AND slot = ?2
        ORDER BY position
        "#,
    )
    .bind(artist_id)
    .bind(slot)
    .fetch_all(pool)
    .await?;
    rows.into_iter()
        .map(|row| {
            Ok(ArtistVisualRegion {
                position: u8::try_from(row.try_get::<i64, _>("position")?)?,
                asset_id: row.try_get("asset_id")?,
                crop_x: row.try_get::<f64, _>("crop_x")? as f32,
                crop_y: row.try_get::<f64, _>("crop_y")? as f32,
                crop_width: row.try_get::<f64, _>("crop_width")? as f32,
                crop_height: row.try_get::<f64, _>("crop_height")? as f32,
                focal_x: row.try_get::<f64, _>("focal_x")? as f32,
                focal_y: row.try_get::<f64, _>("focal_y")? as f32,
            })
        })
        .collect()
}

pub async fn save_artist_visual(
    pool: &DbPool,
    artist_id: i64,
    slot: &str,
    update: &UpdateArtistVisual,
) -> Result<ArtistVisual> {
    const SLOTS: &[&str] = &[
        "avatar",
        "artist_card",
        "search_list",
        "detail_hero",
        "home_feature",
        "playback_background",
    ];
    anyhow::ensure!(SLOTS.contains(&slot), "unsupported artist visual slot");
    anyhow::ensure!(
        update.regions.len() <= 5,
        "an artist visual supports at most 5 regions"
    );
    for (index, region) in update.regions.iter().enumerate() {
        anyhow::ensure!(
            region.position as usize == index,
            "visual region positions must be contiguous"
        );
        anyhow::ensure!(
            region.crop_x >= 0.0
                && region.crop_y >= 0.0
                && region.crop_width > 0.0
                && region.crop_height > 0.0
                && region.crop_x + region.crop_width <= 1.0001
                && region.crop_y + region.crop_height <= 1.0001,
            "visual region crop is out of range"
        );
    }

    let mut transaction = pool.begin().await?;
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT INTO artist_visuals (
            artist_id, slot, asset_id, template, fit, focal_x, focal_y,
            blur, brightness, revision, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 1, ?10)
        ON CONFLICT(artist_id, slot) DO UPDATE SET
            asset_id = excluded.asset_id,
            template = excluded.template,
            fit = excluded.fit,
            focal_x = excluded.focal_x,
            focal_y = excluded.focal_y,
            blur = excluded.blur,
            brightness = excluded.brightness,
            revision = artist_visuals.revision + 1,
            updated_at = excluded.updated_at
        "#,
    )
    .bind(artist_id)
    .bind(slot)
    .bind(update.asset_id)
    .bind(&update.template)
    .bind(&update.fit)
    .bind(update.focal_x.clamp(0.0, 1.0))
    .bind(update.focal_y.clamp(0.0, 1.0))
    .bind(update.blur.clamp(0.0, 40.0))
    .bind(update.brightness.clamp(0.2, 1.5))
    .bind(now)
    .execute(&mut *transaction)
    .await?;
    sqlx::query("DELETE FROM artist_visual_regions WHERE artist_id = ?1 AND slot = ?2")
        .bind(artist_id)
        .bind(slot)
        .execute(&mut *transaction)
        .await?;
    for region in &update.regions {
        sqlx::query(
            r#"
            INSERT INTO artist_visual_regions (
                artist_id, slot, position, asset_id, crop_x, crop_y,
                crop_width, crop_height, focal_x, focal_y
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            "#,
        )
        .bind(artist_id)
        .bind(slot)
        .bind(i64::from(region.position))
        .bind(region.asset_id)
        .bind(region.crop_x)
        .bind(region.crop_y)
        .bind(region.crop_width)
        .bind(region.crop_height)
        .bind(region.focal_x)
        .bind(region.focal_y)
        .execute(&mut *transaction)
        .await?;
    }
    transaction.commit().await?;
    list_artist_visuals(pool, artist_id)
        .await?
        .into_iter()
        .find(|visual| visual.slot == slot)
        .context("saved artist visual was not found")
}

pub async fn artist_visual_source(
    pool: &DbPool,
    artist_id: i64,
    slot: &str,
) -> Result<Option<ArtistVisualSource>> {
    let visual = list_artist_visuals(pool, artist_id)
        .await?
        .into_iter()
        .find(|visual| visual.slot == slot);
    let visual = match visual {
        Some(visual) if visual.asset_id.is_some() || !visual.regions.is_empty() => visual,
        _ => {
            let preferred_types: &[&str] = match slot {
                "detail_hero" | "home_feature" | "playback_background" => {
                    &["background", "landscape", "live", "portrait", "other"]
                }
                _ => &["portrait", "headshot", "other", "background"],
            };
            let mut selected = None;
            for photo_type in preferred_types {
                selected = sqlx::query_scalar::<_, i64>(
                    r#"
                    SELECT id FROM artist_assets
                    WHERE artist_id = ?1 AND deleted_at IS NULL AND photo_type = ?2
                    ORDER BY sort_order, id LIMIT 1
                    "#,
                )
                .bind(artist_id)
                .bind(photo_type)
                .fetch_optional(pool)
                .await?;
                if selected.is_some() {
                    break;
                }
            }
            if selected.is_none() {
                selected = sqlx::query_scalar(
                    r#"
                    SELECT id FROM artist_assets
                    WHERE artist_id = ?1 AND deleted_at IS NULL
                    ORDER BY sort_order, id LIMIT 1
                    "#,
                )
                .bind(artist_id)
                .fetch_optional(pool)
                .await?;
            }
            let Some(asset_id) = selected else {
                return Ok(None);
            };
            ArtistVisual {
                slot: slot.to_string(),
                asset_id: Some(asset_id),
                template: "single".to_string(),
                fit: "cover".to_string(),
                focal_x: 0.5,
                focal_y: 0.5,
                blur: 0.0,
                brightness: 1.0,
                revision: 0,
                regions: Vec::new(),
            }
        }
    };

    let mut asset_ids = visual
        .regions
        .iter()
        .map(|region| region.asset_id)
        .collect::<Vec<_>>();
    if let Some(id) = visual.asset_id {
        asset_ids.push(id);
    }
    asset_ids.sort_unstable();
    asset_ids.dedup();
    let mut assets = Vec::with_capacity(asset_ids.len());
    for id in asset_ids {
        let row = sqlx::query(
            r#"
            SELECT id, artist_id, original_filename, storage_path, mime_type,
                   width, height, byte_size, photo_type, sort_order, created_at
            FROM artist_assets
            WHERE artist_id = ?1 AND id = ?2 AND deleted_at IS NULL
            "#,
        )
        .bind(artist_id)
        .bind(id)
        .fetch_optional(pool)
        .await?;
        if let Some(row) = row {
            let storage_path: String = row.try_get("storage_path")?;
            assets.push(ArtistAssetStorage {
                asset: row_to_artist_asset(row)?,
                storage_path,
            });
        }
    }
    if assets.is_empty() {
        return Ok(None);
    }
    Ok(Some(ArtistVisualSource { visual, assets }))
}

fn row_to_artist_asset(row: sqlx::sqlite::SqliteRow) -> Result<ArtistAsset> {
    Ok(ArtistAsset {
        id: row.try_get("id")?,
        artist_id: row.try_get("artist_id")?,
        original_filename: row.try_get("original_filename")?,
        mime_type: row.try_get("mime_type")?,
        width: u32::try_from(row.try_get::<i64, _>("width")?)?,
        height: u32::try_from(row.try_get::<i64, _>("height")?)?,
        byte_size: u64::try_from(row.try_get::<i64, _>("byte_size")?)?,
        photo_type: row.try_get("photo_type")?,
        sort_order: row.try_get("sort_order")?,
        created_at: parse_datetime(row.try_get::<String, _>("created_at")?)?,
    })
}

pub async fn list_tracks(pool: &DbPool, limit: u32, offset: u32) -> Result<Vec<TrackSummary>> {
    let rows =
        sqlx::query(track_select_sql("GROUP BY t.id ORDER BY t.id LIMIT ?1 OFFSET ?2").as_str())
            .bind(limit as i64)
            .bind(offset as i64)
            .fetch_all(pool)
            .await?;

    rows.into_iter().map(row_to_track).collect()
}

pub async fn playback_queue(pool: &DbPool, zone_id: &str) -> Result<PlaybackQueue> {
    ensure_playback_queue(pool, zone_id).await?;
    let metadata =
        sqlx::query("SELECT revision, mode, current_index FROM playback_queues WHERE zone_id = ?1")
            .bind(zone_id)
            .fetch_one(pool)
            .await?;
    let rows = sqlx::query(
        track_select_sql_extra(
            "pqi.id AS queue_item_id, pqi.position AS queue_position,",
            r#"
            JOIN playback_queue_items pqi ON pqi.track_id = t.id
            WHERE pqi.zone_id = ?1
            GROUP BY pqi.id, t.id
            ORDER BY pqi.position
            "#,
        )
        .as_str(),
    )
    .bind(zone_id)
    .fetch_all(pool)
    .await?;
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        let id = row.try_get("queue_item_id")?;
        let position = row.try_get("queue_position")?;
        items.push(PlaybackQueueItem {
            id,
            position,
            track: row_to_track(row)?,
        });
    }
    let current_index = metadata
        .try_get::<Option<i64>, _>("current_index")?
        .filter(|index| *index >= 0 && (*index as usize) < items.len());
    Ok(PlaybackQueue {
        zone_id: zone_id.to_string(),
        revision: metadata.try_get::<i64, _>("revision")?.max(0) as u64,
        mode: parse_playback_mode(&metadata.try_get::<String, _>("mode")?),
        current_index,
        items,
    })
}

pub async fn replace_playback_queue(
    pool: &DbPool,
    zone_id: &str,
    payload: ReplacePlaybackQueue,
) -> Result<PlaybackQueue> {
    ensure_playback_queue(pool, zone_id).await?;
    let mut tx = pool.begin().await?;
    sqlx::query("DELETE FROM playback_queue_items WHERE zone_id = ?1")
        .bind(zone_id)
        .execute(&mut *tx)
        .await?;
    let now = Utc::now().to_rfc3339();
    for (position, track_id) in payload.track_ids.iter().copied().enumerate() {
        sqlx::query(
            r#"
            INSERT INTO playback_queue_items (zone_id, position, track_id, added_at)
            VALUES (?1, ?2, ?3, ?4)
            "#,
        )
        .bind(zone_id)
        .bind(position as i64)
        .bind(track_id)
        .bind(&now)
        .execute(&mut *tx)
        .await?;
    }
    let current_index = payload
        .start_index
        .filter(|index| *index >= 0 && (*index as usize) < payload.track_ids.len());
    let mode = payload
        .mode
        .map(|mode| playback_mode_as_str(&mode).to_string());
    sqlx::query(
        r#"
        UPDATE playback_queues
        SET revision = revision + 1,
            mode = COALESCE(?2, mode),
            current_index = ?3,
            shuffle_seed = CASE
                WHEN shuffle_seed >= 2147483646 THEN 1
                ELSE shuffle_seed + 1
            END,
            updated_at = ?4
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .bind(mode)
    .bind(current_index)
    .bind(&now)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    playback_queue(pool, zone_id).await
}

pub async fn add_playback_queue_items(
    pool: &DbPool,
    zone_id: &str,
    track_ids: Vec<i64>,
    position: Option<i64>,
) -> Result<PlaybackQueue> {
    let queue = playback_queue(pool, zone_id).await?;
    let mut ids = queue
        .items
        .iter()
        .map(|item| item.track.id)
        .collect::<Vec<_>>();
    let insert_at = position
        .unwrap_or(ids.len() as i64)
        .clamp(0, ids.len() as i64) as usize;
    ids.splice(insert_at..insert_at, track_ids);
    let current_track_id = queue
        .current_index
        .and_then(|index| queue.items.get(index as usize))
        .map(|item| item.track.id);
    let current_index = current_track_id
        .and_then(|track_id| ids.iter().position(|id| *id == track_id))
        .map(|index| index as i64);
    replace_playback_queue(
        pool,
        zone_id,
        ReplacePlaybackQueue {
            track_ids: ids,
            start_index: current_index,
            mode: Some(queue.mode),
        },
    )
    .await
}

pub async fn move_playback_queue_item(
    pool: &DbPool,
    zone_id: &str,
    from: i64,
    to: i64,
) -> Result<PlaybackQueue> {
    let queue = playback_queue(pool, zone_id).await?;
    let mut ids = queue
        .items
        .iter()
        .map(|item| item.track.id)
        .collect::<Vec<_>>();
    if from < 0 || from as usize >= ids.len() || to < 0 || to as usize >= ids.len() {
        anyhow::bail!("queue move is outside the queue bounds");
    }
    let current_track_id = queue
        .current_index
        .and_then(|index| queue.items.get(index as usize))
        .map(|item| item.track.id);
    let value = ids.remove(from as usize);
    ids.insert(to as usize, value);
    let current_index = current_track_id
        .and_then(|track_id| ids.iter().position(|id| *id == track_id))
        .map(|index| index as i64);
    replace_playback_queue(
        pool,
        zone_id,
        ReplacePlaybackQueue {
            track_ids: ids,
            start_index: current_index,
            mode: Some(queue.mode),
        },
    )
    .await
}

pub async fn remove_playback_queue_item(
    pool: &DbPool,
    zone_id: &str,
    item_id: i64,
) -> Result<PlaybackQueue> {
    let queue = playback_queue(pool, zone_id).await?;
    let remove_index = queue
        .items
        .iter()
        .position(|item| item.id == item_id)
        .ok_or_else(|| anyhow::anyhow!("queue item {item_id} does not exist"))?;
    let current_track_id = queue
        .current_index
        .and_then(|index| queue.items.get(index as usize))
        .map(|item| item.track.id);
    let mut ids = queue
        .items
        .iter()
        .map(|item| item.track.id)
        .collect::<Vec<_>>();
    ids.remove(remove_index);
    let current_index = current_track_id
        .and_then(|track_id| ids.iter().position(|id| *id == track_id))
        .map(|index| index as i64);
    replace_playback_queue(
        pool,
        zone_id,
        ReplacePlaybackQueue {
            track_ids: ids,
            start_index: current_index,
            mode: Some(queue.mode),
        },
    )
    .await
}

pub async fn set_playback_mode(
    pool: &DbPool,
    zone_id: &str,
    mode: PlaybackMode,
) -> Result<PlaybackQueue> {
    ensure_playback_queue(pool, zone_id).await?;
    sqlx::query(
        r#"
        UPDATE playback_queues
        SET mode = ?2, revision = revision + 1, updated_at = ?3
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .bind(playback_mode_as_str(&mode))
    .bind(Utc::now().to_rfc3339())
    .execute(pool)
    .await?;
    playback_queue(pool, zone_id).await
}

pub async fn set_playback_queue_current_track(
    pool: &DbPool,
    zone_id: &str,
    track_id: i64,
) -> Result<PlaybackQueue> {
    let mut queue = playback_queue(pool, zone_id).await?;
    if !queue.items.iter().any(|item| item.track.id == track_id) {
        queue = add_playback_queue_items(pool, zone_id, vec![track_id], None).await?;
    }
    let index = queue
        .items
        .iter()
        .position(|item| item.track.id == track_id)
        .ok_or_else(|| anyhow::anyhow!("track {track_id} was not added to the queue"))?;
    if queue.current_index == Some(index as i64) {
        return Ok(queue);
    }
    sqlx::query(
        r#"
        UPDATE playback_queues
        SET current_index = ?2, revision = revision + 1, updated_at = ?3
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .bind(index as i64)
    .bind(Utc::now().to_rfc3339())
    .execute(pool)
    .await?;
    playback_queue(pool, zone_id).await
}

pub async fn step_playback_queue(
    pool: &DbPool,
    zone_id: &str,
    previous: bool,
    automatic: bool,
) -> Result<Option<i64>> {
    let queue = playback_queue(pool, zone_id).await?;
    if queue.items.is_empty() || (automatic && queue.mode == PlaybackMode::Single) {
        return Ok(None);
    }
    let current = queue.current_index.unwrap_or(if previous {
        queue.items.len() as i64
    } else {
        -1
    });
    let next = match queue.mode {
        PlaybackMode::RepeatOne if automatic && current >= 0 => current,
        PlaybackMode::Shuffle => {
            let seed = playback_queue_shuffle_seed(pool, zone_id).await?;
            let mut order = (0..queue.items.len()).collect::<Vec<_>>();
            order.sort_by_key(|index| shuffle_key(queue.items[*index].id as u64, seed as u64));
            let cursor = order
                .iter()
                .position(|index| *index as i64 == current)
                .unwrap_or(if previous {
                    0
                } else {
                    order.len().saturating_sub(1)
                });
            let target = if previous {
                cursor.checked_sub(1)
            } else if cursor + 1 < order.len() {
                Some(cursor + 1)
            } else {
                None
            };
            match target {
                Some(target) => order[target] as i64,
                None => order[if previous { order.len() - 1 } else { 0 }] as i64,
            }
        }
        _ => {
            let candidate = if previous { current - 1 } else { current + 1 };
            if candidate >= 0 && (candidate as usize) < queue.items.len() {
                candidate
            } else if queue.mode == PlaybackMode::RepeatAll || !automatic {
                if previous {
                    queue.items.len() as i64 - 1
                } else {
                    0
                }
            } else {
                return Ok(None);
            }
        }
    };
    sqlx::query(
        r#"
        UPDATE playback_queues
        SET current_index = ?2, revision = revision + 1, updated_at = ?3
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .bind(next)
    .bind(Utc::now().to_rfc3339())
    .execute(pool)
    .await?;
    Ok(queue.items.get(next as usize).map(|item| item.track.id))
}

pub async fn zone_volume(pool: &DbPool, zone_id: &str) -> Result<ZoneVolume> {
    ensure_zone_preferences(pool, zone_id).await?;
    let row = sqlx::query("SELECT volume, muted FROM zone_preferences WHERE zone_id = ?1")
        .bind(zone_id)
        .fetch_one(pool)
        .await?;
    Ok(ZoneVolume {
        zone_id: zone_id.to_string(),
        volume: row.try_get::<f64, _>("volume")? as f32,
        muted: row.try_get::<i64, _>("muted")? != 0,
    })
}

pub async fn set_zone_volume(
    pool: &DbPool,
    zone_id: &str,
    volume: f32,
    muted: Option<bool>,
) -> Result<ZoneVolume> {
    ensure_zone_preferences(pool, zone_id).await?;
    sqlx::query(
        r#"
        UPDATE zone_preferences
        SET volume = ?2,
            muted = COALESCE(?3, muted),
            updated_at = ?4
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .bind(volume.clamp(0.0, 1.0) as f64)
    .bind(muted.map(|value| if value { 1_i64 } else { 0_i64 }))
    .bind(Utc::now().to_rfc3339())
    .execute(pool)
    .await?;
    zone_volume(pool, zone_id).await
}

async fn ensure_playback_queue(pool: &DbPool, zone_id: &str) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT OR IGNORE INTO playback_queues (
            zone_id, revision, mode, current_index, shuffle_seed, created_at, updated_at
        )
        VALUES (?1, 0, 'sequential', NULL, 1, ?2, ?2)
        "#,
    )
    .bind(zone_id)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(())
}

async fn ensure_zone_preferences(pool: &DbPool, zone_id: &str) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT OR IGNORE INTO zone_preferences (
            zone_id, volume, muted, created_at, updated_at
        )
        VALUES (?1, 1.0, 0, ?2, ?2)
        "#,
    )
    .bind(zone_id)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(())
}

async fn playback_queue_shuffle_seed(pool: &DbPool, zone_id: &str) -> Result<i64> {
    ensure_playback_queue(pool, zone_id).await?;
    Ok(
        sqlx::query("SELECT shuffle_seed FROM playback_queues WHERE zone_id = ?1")
            .bind(zone_id)
            .fetch_one(pool)
            .await?
            .try_get("shuffle_seed")?,
    )
}

fn shuffle_key(item_id: u64, seed: u64) -> u64 {
    let mut value = item_id ^ seed.wrapping_mul(0x9E37_79B9_7F4A_7C15);
    value ^= value >> 30;
    value = value.wrapping_mul(0xBF58_476D_1CE4_E5B9);
    value ^= value >> 27;
    value = value.wrapping_mul(0x94D0_49BB_1331_11EB);
    value ^ (value >> 31)
}

fn playback_mode_as_str(mode: &PlaybackMode) -> &'static str {
    match mode {
        PlaybackMode::Single => "single",
        PlaybackMode::RepeatOne => "repeat_one",
        PlaybackMode::Shuffle => "shuffle",
        PlaybackMode::RepeatAll => "repeat_all",
        PlaybackMode::Sequential => "sequential",
    }
}

fn parse_playback_mode(value: &str) -> PlaybackMode {
    match value {
        "single" => PlaybackMode::Single,
        "repeat_one" => PlaybackMode::RepeatOne,
        "shuffle" => PlaybackMode::Shuffle,
        "repeat_all" => PlaybackMode::RepeatAll,
        _ => PlaybackMode::Sequential,
    }
}

pub async fn album_detail(pool: &DbPool, album_id: i64) -> Result<AlbumDetail> {
    let album_row = sqlx::query(
        r#"
        SELECT al.id, al.title, al.album_artist_display, al.date, al.year, al.total_discs,
               al.cover_asset_id, COUNT(t.id) AS track_count
        FROM albums al
        LEFT JOIN tracks t ON t.album_id = al.id
        WHERE al.id = ?1
        GROUP BY al.id
        "#,
    )
    .bind(album_id)
    .fetch_one(pool)
    .await?;

    let track_rows = sqlx::query(
        track_select_sql(
            "WHERE t.album_id = ?1 GROUP BY t.id ORDER BY COALESCE(t.disc_number, 1), COALESCE(t.track_number, 0), t.title",
        )
        .as_str(),
    )
    .bind(album_id)
    .fetch_all(pool)
    .await?;

    Ok(AlbumDetail {
        album: row_to_album(album_row)?,
        tracks: track_rows
            .into_iter()
            .map(row_to_track)
            .collect::<Result<_>>()?,
    })
}

pub async fn track_media_profile(
    pool: &DbPool,
    track_id: i64,
) -> Result<Option<TrackMediaProfile>> {
    let row = sqlx::query(
        r#"
        SELECT
            rt.id AS release_track_id,
            work.id AS work_id,
            work.global_id AS work_global_id,
            work.title AS work_title,
            work.disambiguation AS work_disambiguation,
            recording.id AS recording_id,
            recording.global_id AS recording_global_id,
            recording.title AS recording_title,
            recording.version_title AS recording_version_title,
            recording.recording_kind,
            recording.duration_ms AS recording_duration_ms,
            release.id AS release_id,
            release.global_id AS release_global_id,
            release.album_id AS release_album_id,
            album.title AS release_title,
            release.edition_title AS release_edition_title,
            release.edition_kind AS release_edition_kind,
            album.date AS release_date,
            album.year AS release_year
        FROM legacy_track_catalog_links links
        JOIN release_tracks rt ON rt.id = links.release_track_id
        JOIN catalog_recordings recording ON recording.id = rt.recording_id
        JOIN catalog_works work ON work.id = recording.work_id
        LEFT JOIN release_editions release ON release.id = rt.release_id
        LEFT JOIN albums album ON album.id = release.album_id
        WHERE links.track_id = ?1
        "#,
    )
    .bind(track_id)
    .fetch_optional(pool)
    .await?;
    let Some(row) = row else {
        return Ok(None);
    };

    let release_track_id: i64 = row.try_get("release_track_id")?;
    let recording_id: i64 = row.try_get("recording_id")?;
    let work = CatalogWorkSummary {
        id: row.try_get("work_id")?,
        global_id: row.try_get("work_global_id")?,
        title: row.try_get("work_title")?,
        disambiguation: row.try_get("work_disambiguation")?,
    };
    let recording = CatalogRecordingSummary {
        id: recording_id,
        global_id: row.try_get("recording_global_id")?,
        title: row.try_get("recording_title")?,
        version_title: row.try_get("recording_version_title")?,
        recording_kind: row.try_get("recording_kind")?,
        duration_ms: row.try_get("recording_duration_ms")?,
    };
    let release = release_edition_from_row(&row)?;

    let variant_rows = sqlx::query(
        r#"
        SELECT
            variant.id,
            variant.global_id,
            relation.relation_kind,
            relation.is_preferred,
            variant.codec,
            variant.container,
            variant.bitrate,
            variant.sample_rate,
            variant.bit_depth,
            variant.channels,
            variant.duration_ms,
            variant.content_hash,
            master.id AS master_id,
            master.global_id AS master_global_id,
            master.label AS master_label,
            master.mastering_kind,
            master.release_year AS master_release_year
        FROM release_track_media_variants relation
        JOIN media_variants variant ON variant.id = relation.media_variant_id
        JOIN audio_masters master ON master.id = variant.audio_master_id
        WHERE relation.release_track_id = ?1
        ORDER BY relation.is_preferred DESC,
                 COALESCE(variant.bit_depth, 0) DESC,
                 COALESCE(variant.sample_rate, 0) DESC,
                 COALESCE(variant.bitrate, 0) DESC,
                 variant.id
        "#,
    )
    .bind(release_track_id)
    .fetch_all(pool)
    .await?;
    let mut variants = Vec::with_capacity(variant_rows.len());
    for variant_row in variant_rows {
        let variant_id: i64 = variant_row.try_get("id")?;
        let replica_rows = sqlx::query(
            r#"
            SELECT
                replica.id,
                replica.file_id,
                replica.device_id,
                COALESCE(device.name, 'Core local') AS device_name,
                replica.source_kind,
                CASE
                    WHEN file.deleted_at IS NOT NULL THEN 'missing'
                    ELSE replica.availability_state
                END AS availability_state,
                replica.is_primary,
                file.relative_path,
                root.external_id AS root_external_id,
                file.client_file_id,
                replica.last_verified_at
            FROM media_replicas replica
            LEFT JOIN devices device ON device.id = replica.device_id
            LEFT JOIN files file ON file.id = replica.file_id
            LEFT JOIN library_roots root ON root.id = replica.library_root_id
            WHERE replica.media_variant_id = ?1
            ORDER BY replica.is_primary DESC, device_name, replica.id
            "#,
        )
        .bind(variant_id)
        .fetch_all(pool)
        .await?;
        let replicas = replica_rows
            .into_iter()
            .map(|replica_row| {
                let last_verified_at: Option<String> = replica_row.try_get("last_verified_at")?;
                Ok(MediaReplicaSummary {
                    id: replica_row.try_get("id")?,
                    file_id: replica_row.try_get("file_id")?,
                    device_id: replica_row.try_get("device_id")?,
                    device_name: replica_row.try_get("device_name")?,
                    source_kind: replica_row.try_get("source_kind")?,
                    availability_state: replica_row.try_get("availability_state")?,
                    is_primary: replica_row.try_get::<i64, _>("is_primary")? != 0,
                    relative_path: replica_row.try_get("relative_path")?,
                    root_external_id: replica_row.try_get("root_external_id")?,
                    client_file_id: replica_row.try_get("client_file_id")?,
                    last_verified_at: last_verified_at.map(parse_datetime).transpose()?,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        variants.push(MediaVariantSummary {
            id: variant_id,
            global_id: variant_row.try_get("global_id")?,
            relation_kind: variant_row.try_get("relation_kind")?,
            is_preferred: variant_row.try_get::<i64, _>("is_preferred")? != 0,
            codec: variant_row.try_get("codec")?,
            container: variant_row.try_get("container")?,
            bitrate: variant_row.try_get("bitrate")?,
            sample_rate: variant_row.try_get("sample_rate")?,
            bit_depth: variant_row.try_get("bit_depth")?,
            channels: variant_row.try_get("channels")?,
            duration_ms: variant_row.try_get("duration_ms")?,
            content_hash: variant_row.try_get("content_hash")?,
            master: AudioMasterSummary {
                id: variant_row.try_get("master_id")?,
                global_id: variant_row.try_get("master_global_id")?,
                label: variant_row.try_get("master_label")?,
                mastering_kind: variant_row.try_get("mastering_kind")?,
                release_year: variant_row.try_get("master_release_year")?,
            },
            replicas,
        });
    }

    let related_rows = sqlx::query(
        r#"
        SELECT
            rt.id AS related_release_track_id,
            MIN(links.track_id) AS legacy_track_id,
            rt.title,
            rt.disc_number,
            rt.track_number,
            release.id AS release_id,
            release.global_id AS release_global_id,
            release.album_id AS release_album_id,
            album.title AS release_title,
            release.edition_title AS release_edition_title,
            release.edition_kind AS release_edition_kind,
            album.date AS release_date,
            album.year AS release_year
        FROM release_tracks rt
        LEFT JOIN legacy_track_catalog_links links ON links.release_track_id = rt.id
        LEFT JOIN release_editions release ON release.id = rt.release_id
        LEFT JOIN albums album ON album.id = release.album_id
        WHERE rt.recording_id = ?1
        GROUP BY rt.id
        ORDER BY COALESCE(album.year, 0), COALESCE(album.title, ''), rt.disc_number, rt.track_number
        "#,
    )
    .bind(recording_id)
    .fetch_all(pool)
    .await?;
    let related_release_tracks = related_rows
        .into_iter()
        .map(|related_row| {
            let related_release_track_id: i64 = related_row.try_get("related_release_track_id")?;
            Ok(RelatedReleaseTrackSummary {
                release_track_id: related_release_track_id,
                legacy_track_id: related_row.try_get("legacy_track_id")?,
                release: release_edition_from_row(&related_row)?,
                title: related_row.try_get("title")?,
                disc_number: related_row.try_get("disc_number")?,
                track_number: related_row.try_get("track_number")?,
                is_current: related_release_track_id == release_track_id,
            })
        })
        .collect::<Result<Vec<_>>>()?;

    Ok(Some(TrackMediaProfile {
        release_track_id,
        work,
        recording,
        release,
        variants,
        related_release_tracks,
    }))
}

pub async fn recording_link_candidates(
    pool: &DbPool,
    track_id: i64,
    limit: u32,
) -> Result<Vec<RecordingLinkCandidate>> {
    let target = sqlx::query(
        r#"
        SELECT
            t.title,
            t.duration_ms,
            rt.recording_id,
            recording.recording_kind,
            COALESCE(GROUP_CONCAT(artist.name, char(31)), '') AS artists
        FROM tracks t
        JOIN legacy_track_catalog_links links ON links.track_id = t.id
        JOIN release_tracks rt ON rt.id = links.release_track_id
        JOIN catalog_recordings recording ON recording.id = rt.recording_id
        LEFT JOIN track_artists ta ON ta.track_id = t.id AND ta.role = 'primary'
        LEFT JOIN artists artist ON artist.id = ta.artist_id
        WHERE t.id = ?1
        GROUP BY t.id
        "#,
    )
    .bind(track_id)
    .fetch_one(pool)
    .await?;
    let target_title: String = target.try_get("title")?;
    let target_duration: Option<i64> = target.try_get("duration_ms")?;
    let target_recording_id: i64 = target.try_get("recording_id")?;
    let target_recording_kind: String = target.try_get("recording_kind")?;
    let target_artists = normalized_artist_names(&target.try_get::<String, _>("artists")?);

    let rows = sqlx::query(
        r#"
        SELECT
            t.id AS track_id,
            rt.id AS release_track_id,
            rt.recording_id,
            recording.recording_kind,
            t.title,
            t.duration_ms,
            t.album_id,
            album.title AS album_title,
            album.year,
            t.disc_number,
            t.track_number,
            COALESCE(GROUP_CONCAT(artist.name, char(31)), '') AS artists,
            COALESCE(GROUP_CONCAT(DISTINCT artist.name), NULL) AS artist_display
        FROM tracks t
        JOIN legacy_track_catalog_links links ON links.track_id = t.id
        JOIN release_tracks rt ON rt.id = links.release_track_id
        JOIN catalog_recordings recording ON recording.id = rt.recording_id
        LEFT JOIN albums album ON album.id = t.album_id
        LEFT JOIN track_artists ta ON ta.track_id = t.id AND ta.role = 'primary'
        LEFT JOIN artists artist ON artist.id = ta.artist_id
        WHERE t.id <> ?1
          AND lower(trim(t.title)) = lower(trim(?2))
          AND (
              ?3 IS NULL
              OR t.duration_ms IS NULL
              OR ABS(t.duration_ms - ?3) <= 15000
          )
        GROUP BY t.id
        LIMIT 250
        "#,
    )
    .bind(track_id)
    .bind(&target_title)
    .bind(target_duration)
    .fetch_all(pool)
    .await?;

    let mut candidates = Vec::new();
    for row in rows {
        let recording_id: i64 = row.try_get("recording_id")?;
        let duration_ms: Option<i64> = row.try_get("duration_ms")?;
        let recording_kind: String = row.try_get("recording_kind")?;
        let artists = normalized_artist_names(&row.try_get::<String, _>("artists")?);
        let mut confidence = 0.45_f32;
        let mut reasons = vec!["same_title".to_string()];
        if !target_artists.is_empty()
            && target_artists.iter().any(|artist| artists.contains(artist))
        {
            confidence += 0.25;
            reasons.push("same_primary_artist".to_string());
        }
        if let (Some(target_duration), Some(duration_ms)) = (target_duration, duration_ms) {
            let difference = (target_duration - duration_ms).abs();
            if difference <= 1_000 {
                confidence += 0.2;
                reasons.push("duration_within_1s".to_string());
            } else if difference <= 3_000 {
                confidence += 0.15;
                reasons.push("duration_within_3s".to_string());
            } else if difference <= 10_000 {
                confidence += 0.08;
                reasons.push("duration_within_10s".to_string());
            }
        }
        if recording_kind == target_recording_kind {
            confidence += 0.1;
            reasons.push("same_recording_kind".to_string());
        }
        let already_linked = recording_id == target_recording_id;
        if already_linked {
            confidence = 1.0;
            reasons.push("already_linked".to_string());
        }
        if confidence < 0.55 {
            continue;
        }
        candidates.push(RecordingLinkCandidate {
            track_id: row.try_get("track_id")?,
            release_track_id: row.try_get("release_track_id")?,
            recording_id,
            title: row.try_get("title")?,
            artist_display: row.try_get("artist_display")?,
            album_id: row.try_get("album_id")?,
            album_title: row.try_get("album_title")?,
            year: row.try_get("year")?,
            disc_number: row.try_get("disc_number")?,
            track_number: row.try_get("track_number")?,
            duration_ms,
            already_linked,
            confidence: confidence.min(1.0),
            reasons,
        });
    }
    candidates.sort_by(|left, right| {
        right
            .already_linked
            .cmp(&left.already_linked)
            .then_with(|| {
                right
                    .confidence
                    .partial_cmp(&left.confidence)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .then_with(|| left.album_title.cmp(&right.album_title))
            .then_with(|| left.track_id.cmp(&right.track_id))
    });
    candidates.truncate(limit.clamp(1, 100) as usize);
    Ok(candidates)
}

fn normalized_artist_names(value: &str) -> Vec<String> {
    let mut names = value
        .split('\u{1f}')
        .map(normalize_text)
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>();
    names.sort();
    names.dedup();
    names
}

pub async fn link_track_to_recording(
    pool: &DbPool,
    track_id: i64,
    source_track_id: i64,
) -> Result<TrackMediaProfile> {
    if track_id == source_track_id {
        bail!("a release track cannot be linked to itself");
    }
    let mut transaction = pool.begin().await?;
    let source_recording_id: i64 = sqlx::query_scalar(
        r#"
        SELECT rt.recording_id
        FROM legacy_track_catalog_links links
        JOIN release_tracks rt ON rt.id = links.release_track_id
        WHERE links.track_id = ?1
        "#,
    )
    .bind(source_track_id)
    .fetch_one(&mut *transaction)
    .await?;
    let target_release_track_id: i64 = sqlx::query_scalar(
        "SELECT release_track_id FROM legacy_track_catalog_links WHERE track_id = ?1",
    )
    .bind(track_id)
    .fetch_one(&mut *transaction)
    .await?;
    let now = Utc::now().to_rfc3339();
    sqlx::query("UPDATE release_tracks SET recording_id = ?1, updated_at = ?2 WHERE id = ?3")
        .bind(source_recording_id)
        .bind(&now)
        .bind(target_release_track_id)
        .execute(&mut *transaction)
        .await?;
    sqlx::query(
        r#"
        UPDATE audio_masters
        SET recording_id = ?1, updated_at = ?2
        WHERE id IN (
            SELECT variant.audio_master_id
            FROM release_track_media_variants relation
            JOIN media_variants variant ON variant.id = relation.media_variant_id
            WHERE relation.release_track_id = ?3
        )
        "#,
    )
    .bind(source_recording_id)
    .bind(&now)
    .bind(target_release_track_id)
    .execute(&mut *transaction)
    .await?;
    sqlx::query(
        r#"
        UPDATE legacy_track_catalog_links
        SET match_kind = 'confirmed_recording', match_confidence = 1.0, updated_at = ?1
        WHERE track_id = ?2
        "#,
    )
    .bind(&now)
    .bind(track_id)
    .execute(&mut *transaction)
    .await?;
    transaction.commit().await?;
    track_media_profile(pool, track_id)
        .await?
        .context("track media profile is missing after recording link")
}

pub async fn detach_track_recording(pool: &DbPool, track_id: i64) -> Result<TrackMediaProfile> {
    let mut transaction = pool.begin().await?;
    let identity = sqlx::query(
        r#"
        SELECT
            links.release_track_id,
            t.title,
            t.subtitle,
            t.duration_ms
        FROM tracks t
        JOIN legacy_track_catalog_links links ON links.track_id = t.id
        WHERE t.id = ?1
        "#,
    )
    .bind(track_id)
    .fetch_one(&mut *transaction)
    .await?;
    let release_track_id: i64 = identity.try_get("release_track_id")?;
    let title: String = identity.try_get("title")?;
    let subtitle: Option<String> = identity.try_get("subtitle")?;
    let duration_ms: Option<i64> = identity.try_get("duration_ms")?;
    let now = Utc::now().to_rfc3339();
    let work_id: i64 = sqlx::query_scalar(
        r#"
        INSERT INTO catalog_works (
            global_id, title, normalized_title, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?4)
        RETURNING id
        "#,
    )
    .bind(Uuid::now_v7().to_string())
    .bind(&title)
    .bind(normalize_text(&title))
    .bind(&now)
    .fetch_one(&mut *transaction)
    .await?;
    let recording_id: i64 = sqlx::query_scalar(
        r#"
        INSERT INTO catalog_recordings (
            global_id, work_id, title, version_title, recording_kind,
            duration_ms, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)
        RETURNING id
        "#,
    )
    .bind(Uuid::now_v7().to_string())
    .bind(work_id)
    .bind(&title)
    .bind(&subtitle)
    .bind(inferred_recording_kind(subtitle.as_deref()))
    .bind(duration_ms)
    .bind(&now)
    .fetch_one(&mut *transaction)
    .await?;
    sqlx::query("UPDATE release_tracks SET recording_id = ?1, updated_at = ?2 WHERE id = ?3")
        .bind(recording_id)
        .bind(&now)
        .bind(release_track_id)
        .execute(&mut *transaction)
        .await?;
    sqlx::query(
        r#"
        UPDATE audio_masters
        SET recording_id = ?1, updated_at = ?2
        WHERE id IN (
            SELECT variant.audio_master_id
            FROM release_track_media_variants relation
            JOIN media_variants variant ON variant.id = relation.media_variant_id
            WHERE relation.release_track_id = ?3
        )
        "#,
    )
    .bind(recording_id)
    .bind(&now)
    .bind(release_track_id)
    .execute(&mut *transaction)
    .await?;
    sqlx::query(
        r#"
        UPDATE legacy_track_catalog_links
        SET match_kind = 'detached', match_confidence = 1.0, updated_at = ?1
        WHERE track_id = ?2
        "#,
    )
    .bind(&now)
    .bind(track_id)
    .execute(&mut *transaction)
    .await?;
    transaction.commit().await?;
    track_media_profile(pool, track_id)
        .await?
        .context("track media profile is missing after recording detach")
}

fn release_edition_from_row(
    row: &sqlx::sqlite::SqliteRow,
) -> Result<Option<ReleaseEditionSummary>> {
    let id: Option<i64> = row.try_get("release_id")?;
    let Some(id) = id else {
        return Ok(None);
    };
    Ok(Some(ReleaseEditionSummary {
        id,
        global_id: row.try_get("release_global_id")?,
        album_id: row.try_get("release_album_id")?,
        title: row.try_get("release_title")?,
        edition_title: row.try_get("release_edition_title")?,
        edition_kind: row.try_get("release_edition_kind")?,
        date: row.try_get("release_date")?,
        year: row.try_get("release_year")?,
    }))
}

pub async fn track_detail(pool: &DbPool, track_id: i64) -> Result<TrackDetail> {
    let track_row = sqlx::query(track_select_sql("WHERE t.id = ?1 GROUP BY t.id").as_str())
        .bind(track_id)
        .fetch_one(pool)
        .await?;
    let track = row_to_track(track_row)?;

    let file_row = sqlx::query(
        r#"
        SELECT f.path, f.relative_path, f.extension, f.size_bytes, f.modified_at, f.scan_status
        FROM tracks t
        JOIN files f ON f.id = t.file_id
        WHERE t.id = ?1
        "#,
    )
    .bind(track_id)
    .fetch_one(pool)
    .await?;

    let genres = sqlx::query(
        r#"
        SELECT g.name
        FROM track_genres tg
        JOIN genres g ON g.id = tg.genre_id
        WHERE tg.track_id = ?1
        ORDER BY g.name
        "#,
    )
    .bind(track_id)
    .fetch_all(pool)
    .await?
    .into_iter()
    .map(|row| row.try_get("name"))
    .collect::<Result<Vec<String>, sqlx::Error>>()?;
    let composers = track_artist_role_names(pool, track_id, "composer").await?;
    let lyricists = track_artist_role_names(pool, track_id, "lyricist").await?;

    let lyrics = sqlx::query(
        r#"
        SELECT kind, text, language, translation_text, pronunciation_text,
               offset_ms, source, revision, parsed_json
        FROM lyrics
        WHERE track_id = ?1
        "#,
    )
    .bind(track_id)
    .fetch_optional(pool)
    .await?
    .map(|row| {
        let parsed_json: Option<String> = row.try_get("parsed_json")?;
        Ok::<_, sqlx::Error>(LyricPayload {
            kind: row.try_get("kind")?,
            text: row.try_get("text")?,
            language: row.try_get("language")?,
            translation: row.try_get("translation_text")?,
            pronunciation: row.try_get("pronunciation_text")?,
            offset_ms: row.try_get("offset_ms")?,
            source: row.try_get("source")?,
            revision: row.try_get("revision")?,
            cues: parsed_json
                .as_deref()
                .and_then(|value| serde_json::from_str(value).ok())
                .unwrap_or_default(),
        })
    })
    .transpose()?;

    Ok(TrackDetail {
        track,
        file_path: file_row.try_get("path")?,
        relative_path: file_row.try_get("relative_path")?,
        extension: file_row.try_get("extension")?,
        size_bytes: file_row.try_get("size_bytes")?,
        modified_at: parse_datetime(file_row.try_get::<String, _>("modified_at")?)?,
        scan_status: file_row.try_get("scan_status")?,
        genres,
        composers,
        lyricists,
        lyrics,
        media: track_media_profile(pool, track_id).await?,
    })
}

async fn track_artist_role_names(pool: &DbPool, track_id: i64, role: &str) -> Result<Vec<String>> {
    Ok(sqlx::query(
        r#"
        SELECT ar.name
        FROM track_artists ta
        JOIN artists ar ON ar.id = ta.artist_id
        WHERE ta.track_id = ?1 AND ta.role = ?2
        ORDER BY ta.position, ar.name
        "#,
    )
    .bind(track_id)
    .bind(role)
    .fetch_all(pool)
    .await?
    .into_iter()
    .map(|row| row.try_get("name"))
    .collect::<Result<Vec<String>, sqlx::Error>>()?)
}

async fn current_track_ingest(pool: &DbPool, track_id: i64) -> Result<TrackIngest> {
    let row = sqlx::query(
        r#"
        SELECT
            t.title, t.sort_title, t.subtitle, al.title AS album,
            t.disc_number, t.disc_total, t.track_number, t.track_total,
            t.duration_ms, t.date, t.year, t.bpm, t.comment,
            t.tag_rating, t.tag_rating_scale, t.album_id
        FROM tracks t
        LEFT JOIN albums al ON al.id = t.album_id
        WHERE t.id = ?1
        "#,
    )
    .bind(track_id)
    .fetch_one(pool)
    .await?;
    let album_id: Option<i64> = row.try_get("album_id")?;
    let album_artists = if let Some(album_id) = album_id {
        sqlx::query(
            r#"
            SELECT ar.name
            FROM album_artists aa
            JOIN artists ar ON ar.id = aa.artist_id
            WHERE aa.album_id = ?1
            ORDER BY aa.position, ar.name
            "#,
        )
        .bind(album_id)
        .fetch_all(pool)
        .await?
        .into_iter()
        .map(|row| row.try_get("name"))
        .collect::<Result<Vec<String>, sqlx::Error>>()?
    } else {
        Vec::new()
    };
    let genres = sqlx::query(
        r#"
        SELECT g.name
        FROM track_genres tg
        JOIN genres g ON g.id = tg.genre_id
        WHERE tg.track_id = ?1
        ORDER BY g.name
        "#,
    )
    .bind(track_id)
    .fetch_all(pool)
    .await?
    .into_iter()
    .map(|row| row.try_get("name"))
    .collect::<Result<Vec<String>, sqlx::Error>>()?;
    let lyrics = sqlx::query("SELECT kind, text FROM lyrics WHERE track_id = ?1")
        .bind(track_id)
        .fetch_optional(pool)
        .await?;

    Ok(TrackIngest {
        title: row.try_get("title")?,
        sort_title: row.try_get("sort_title")?,
        subtitle: row.try_get("subtitle")?,
        album: row.try_get("album")?,
        track_artists: track_artist_role_names(pool, track_id, "primary").await?,
        album_artists,
        composers: track_artist_role_names(pool, track_id, "composer").await?,
        lyricists: track_artist_role_names(pool, track_id, "lyricist").await?,
        genres,
        disc_number: row.try_get("disc_number")?,
        disc_total: row.try_get("disc_total")?,
        track_number: row.try_get("track_number")?,
        track_total: row.try_get("track_total")?,
        duration_ms: row.try_get("duration_ms")?,
        date: row.try_get("date")?,
        year: row.try_get("year")?,
        bpm: row.try_get("bpm")?,
        comment: row.try_get("comment")?,
        lyrics: lyrics
            .as_ref()
            .map(|lyrics| lyrics.try_get("text"))
            .transpose()?,
        lyrics_kind: lyrics
            .as_ref()
            .map(|lyrics| lyrics.try_get("kind"))
            .transpose()?,
        tag_rating: row.try_get("tag_rating")?,
        tag_rating_scale: row.try_get("tag_rating_scale")?,
    })
}

pub async fn track_edit_snapshot(pool: &DbPool, track_id: i64) -> Result<TrackEditSnapshot> {
    let detail = track_detail(pool, track_id).await?;
    let file_id = detail.track.file_id;
    let source = match load_track_metadata_source(pool, file_id).await? {
        Some(source) => source,
        None => current_track_ingest(pool, track_id).await?,
    };
    let overrides = load_track_metadata_overrides(pool, track_id).await?;
    let mut effective = source.clone();
    apply_metadata_overrides(&mut effective, &overrides)?;
    let revision =
        sqlx::query_scalar("SELECT revision FROM track_metadata_state WHERE track_id = ?1")
            .bind(track_id)
            .fetch_optional(pool)
            .await?
            .unwrap_or(0);
    let fields = TRACK_METADATA_FIELDS
        .iter()
        .map(|(key, label, scope, value_kind)| {
            let override_value = overrides.get(*key).cloned();
            TrackMetadataField {
                key: (*key).to_string(),
                label: (*label).to_string(),
                scope: (*scope).to_string(),
                value_kind: (*value_kind).to_string(),
                effective_value: metadata_field_value(&effective, key),
                file_value: metadata_field_value(&source, key),
                source: if override_value.is_some() {
                    "manual".to_string()
                } else {
                    "file".to_string()
                },
                override_value,
            }
        })
        .collect();
    let file_lyrics = source
        .lyrics
        .as_ref()
        .filter(|text| !text.trim().is_empty())
        .map(|text| LyricPayload {
            kind: source
                .lyrics_kind
                .clone()
                .unwrap_or_else(|| "text".to_string()),
            text: text.clone(),
            language: None,
            translation: None,
            pronunciation: None,
            offset_ms: 0,
            source: "file".to_string(),
            revision: 0,
            cues: Vec::new(),
        });
    Ok(TrackEditSnapshot {
        detail,
        revision,
        fields,
        file_lyrics,
    })
}

pub async fn update_track_metadata(
    pool: &DbPool,
    track_id: i64,
    update: &TrackMetadataUpdate,
    parsed_lyrics: Option<&[protocol::LyricCue]>,
) -> Result<TrackEditSnapshot> {
    let identity = sqlx::query(
        r#"
        SELECT t.file_id, f.library_root_id
        FROM tracks t
        JOIN files f ON f.id = t.file_id
        WHERE t.id = ?1
        "#,
    )
    .bind(track_id)
    .fetch_one(pool)
    .await?;
    let file_id: i64 = identity.try_get("file_id")?;
    let library_root_id: i64 = identity.try_get("library_root_id")?;
    let source = match load_track_metadata_source(pool, file_id).await? {
        Some(source) => source,
        None => {
            let source = current_track_ingest(pool, track_id).await?;
            save_track_metadata_source(pool, file_id, &source).await?;
            source
        }
    };
    let mut overrides = load_track_metadata_overrides(pool, track_id).await?;

    let mut affected_fields = Vec::<String>::new();
    for key in &update.clear_fields {
        if !is_supported_metadata_field(key) {
            bail!("unsupported metadata field: {key}");
        }
        overrides.remove(key);
        if !affected_fields.contains(key) {
            affected_fields.push(key.clone());
        }
    }
    for field in &update.fields {
        if !is_supported_metadata_field(&field.key) {
            bail!("unsupported metadata field: {}", field.key);
        }
        let value = normalize_metadata_value(&field.key, &field.value)?;
        if value == metadata_field_value(&source, &field.key) {
            overrides.remove(&field.key);
        } else {
            overrides.insert(field.key.clone(), value);
        }
        if !affected_fields.contains(&field.key) {
            affected_fields.push(field.key.clone());
        }
    }
    let mut effective = source.clone();
    apply_metadata_overrides(&mut effective, &overrides)?;
    if effective.title.trim().is_empty() {
        bail!("title cannot be empty");
    }

    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT OR IGNORE INTO track_metadata_state (track_id, revision, updated_at)
        VALUES (?1, 0, ?2)
        "#,
    )
    .bind(track_id)
    .bind(&now)
    .execute(pool)
    .await?;
    let current_revision: i64 =
        sqlx::query_scalar("SELECT revision FROM track_metadata_state WHERE track_id = ?1")
            .bind(track_id)
            .fetch_one(pool)
            .await?;
    if let Some(expected_revision) = update.expected_revision {
        if expected_revision != current_revision {
            bail!(
                "metadata revision conflict: expected {expected_revision}, current {current_revision}"
            );
        }
    }
    let next_revision = current_revision + 1;
    let updated = sqlx::query(
        r#"
        UPDATE track_metadata_state
        SET revision = ?1, updated_at = ?2
        WHERE track_id = ?3 AND revision = ?4
        "#,
    )
    .bind(next_revision)
    .bind(&now)
    .bind(track_id)
    .bind(current_revision)
    .execute(pool)
    .await?;
    if updated.rows_affected() != 1 {
        bail!("metadata revision conflict");
    }

    for key in &affected_fields {
        sqlx::query("DELETE FROM track_metadata_overrides WHERE track_id = ?1 AND field_key = ?2")
            .bind(track_id)
            .bind(key)
            .execute(pool)
            .await?;
        if let Some(value) = overrides.get(key) {
            sqlx::query(
                r#"
                INSERT INTO track_metadata_overrides (
                    track_id, field_key, value_json, created_at, updated_at
                )
                VALUES (?1, ?2, ?3, ?4, ?4)
                "#,
            )
            .bind(track_id)
            .bind(key)
            .bind(serde_json::to_string(value)?)
            .bind(&now)
            .execute(pool)
            .await?;
        }
    }

    if update.clear_lyrics_override {
        sqlx::query("DELETE FROM lyrics WHERE track_id = ?1 AND is_locked = 1")
            .bind(track_id)
            .execute(pool)
            .await?;
    }
    let refreshed_track_id = upsert_track(pool, file_id, library_root_id, &effective).await?;
    let stored_file = file_ingest_by_id(pool, file_id).await?;
    ensure_track_media_graph(pool, refreshed_track_id, file_id, &stored_file, &effective).await?;

    if let Some(lyrics) = &update.lyrics {
        let kind = if lyrics.kind.trim().is_empty() {
            "text"
        } else {
            lyrics.kind.trim()
        };
        let language = trimmed_option(lyrics.language.as_deref());
        let translation = trimmed_option(lyrics.translation.as_deref());
        let pronunciation = trimmed_option(lyrics.pronunciation.as_deref());
        let parsed_json = parsed_lyrics.map(serde_json::to_string).transpose()?;
        sqlx::query(
            r#"
            INSERT INTO lyrics (
                track_id, kind, text, parsed_json, language, translation_text,
                pronunciation_text, offset_ms, source, is_locked, revision,
                created_at, updated_at
            )
            VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'manual', 1, 1, ?9, ?9
            )
            ON CONFLICT(track_id) DO UPDATE SET
                kind = excluded.kind,
                text = excluded.text,
                parsed_json = excluded.parsed_json,
                language = excluded.language,
                translation_text = excluded.translation_text,
                pronunciation_text = excluded.pronunciation_text,
                offset_ms = excluded.offset_ms,
                source = 'manual',
                is_locked = 1,
                revision = lyrics.revision + 1,
                updated_at = excluded.updated_at
            "#,
        )
        .bind(track_id)
        .bind(kind)
        .bind(lyrics.text.trim())
        .bind(parsed_json)
        .bind(language)
        .bind(translation)
        .bind(pronunciation)
        .bind(lyrics.offset_ms)
        .bind(&now)
        .execute(pool)
        .await?;
        rebuild_track_search_row(pool, track_id).await?;
    }

    sqlx::query(
        r#"
        INSERT INTO track_metadata_revisions (
            track_id, revision, changes_json, created_at
        )
        VALUES (?1, ?2, ?3, ?4)
        "#,
    )
    .bind(track_id)
    .bind(next_revision)
    .bind(serde_json::to_string(update)?)
    .bind(now)
    .execute(pool)
    .await?;

    track_edit_snapshot(pool, track_id).await
}

pub async fn track_file_path(pool: &DbPool, track_id: i64) -> Result<String> {
    Ok(sqlx::query(
        r#"
        SELECT f.path
        FROM tracks t
        JOIN files f ON f.id = t.file_id
        WHERE t.id = ?1
        "#,
    )
    .bind(track_id)
    .fetch_one(pool)
    .await?
    .try_get("path")?)
}

pub async fn search_tracks(pool: &DbPool, query: &str, limit: u32) -> Result<Vec<TrackSummary>> {
    let pattern = format!("%{}%", query);
    let rows = sqlx::query(
        track_select_sql(
            r#"
            WHERE t.title LIKE ?1
               OR al.title LIKE ?1
               OR EXISTS (
                    SELECT 1
                    FROM track_artists ta2
                    JOIN artists ar2 ON ar2.id = ta2.artist_id
                    WHERE ta2.track_id = t.id AND ar2.name LIKE ?1
               )
               OR EXISTS (
                    SELECT 1
                    FROM lyrics l
                    WHERE l.track_id = t.id AND l.text LIKE ?1
               )
            GROUP BY t.id
            ORDER BY t.id
            LIMIT ?2
            "#,
        )
        .as_str(),
    )
    .bind(pattern)
    .bind(limit as i64)
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_track).collect()
}

pub async fn search_albums(pool: &DbPool, query: &str, limit: u32) -> Result<Vec<AlbumSummary>> {
    let pattern = format!("%{}%", query);
    let rows = sqlx::query(
        r#"
        SELECT al.id, al.title, al.album_artist_display, al.date, al.year, al.total_discs,
               al.cover_asset_id, COUNT(t.id) AS track_count
        FROM albums al
        LEFT JOIN tracks t ON t.album_id = al.id
        WHERE al.title LIKE ?1 OR al.album_artist_display LIKE ?1
        GROUP BY al.id
        ORDER BY al.title COLLATE NOCASE
        LIMIT ?2
        "#,
    )
    .bind(pattern)
    .bind(limit as i64)
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_album).collect()
}

pub async fn search_artists(pool: &DbPool, query: &str, limit: u32) -> Result<Vec<ArtistSummary>> {
    let pattern = format!("%{}%", query);
    let rows = sqlx::query(
        r#"
        SELECT ar.id,
               COALESCE(NULLIF(ap.display_name, ''), ar.name) AS name,
               COALESCE(NULLIF(ap.sort_name, ''), ar.sort_name) AS sort_name,
               COUNT(DISTINCT ta.track_id) AS track_count,
               COUNT(DISTINCT aa.album_id) AS album_count,
               COALESCE((SELECT MAX(av.revision)
                         FROM artist_visuals av
                         WHERE av.artist_id = ar.id), 0) AS artwork_revision,
               EXISTS(SELECT 1
                      FROM artist_assets ai
                      WHERE ai.artist_id = ar.id AND ai.deleted_at IS NULL) AS has_artwork
        FROM artists ar
        LEFT JOIN artist_profiles ap ON ap.artist_id = ar.id
        LEFT JOIN track_artists ta ON ta.artist_id = ar.id
        LEFT JOIN album_artists aa ON aa.artist_id = ar.id
        WHERE ar.name LIKE ?1 OR ap.display_name LIKE ?1 OR ap.aliases_json LIKE ?1
        GROUP BY ar.id
        ORDER BY COALESCE(NULLIF(ap.sort_name, ''), ar.sort_name,
                          NULLIF(ap.display_name, ''), ar.name) COLLATE NOCASE
        LIMIT ?2
        "#,
    )
    .bind(pattern)
    .bind(limit as i64)
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_artist).collect()
}

pub async fn list_playlists(
    pool: &DbPool,
    include_max_tag_rating_as_favorite: bool,
) -> Result<Vec<PlaylistSummary>> {
    let rows = sqlx::query(
        r#"
        SELECT p.id, p.name, p.kind, p.description, p.rules_json, p.created_at, p.updated_at,
               COUNT(pi.id) AS track_count
        FROM playlists p
        LEFT JOIN playlist_items pi ON pi.playlist_id = p.id
        GROUP BY p.id
        ORDER BY p.updated_at DESC, p.name COLLATE NOCASE
        "#,
    )
    .fetch_all(pool)
    .await?;

    let mut playlists = Vec::with_capacity(rows.len());
    for row in rows {
        let kind_text: String = row.try_get("kind")?;
        let rules_json: Option<String> = row.try_get("rules_json")?;
        let track_count = if kind_text == "smart" {
            let rules = parse_rules_json(rules_json.as_deref())?;
            smart_playlist_track_count(pool, rules.as_ref(), include_max_tag_rating_as_favorite)
                .await?
        } else {
            row.try_get("track_count")?
        };
        playlists.push(row_to_playlist_summary(row, track_count)?);
    }

    Ok(playlists)
}

pub async fn create_playlist(
    pool: &DbPool,
    payload: NewPlaylist,
    include_max_tag_rating_as_favorite: bool,
) -> Result<PlaylistDetail> {
    let name = payload.name.trim();
    if name.is_empty() {
        anyhow::bail!("playlist name cannot be empty");
    }

    let now = Utc::now().to_rfc3339();
    let rules_json = payload
        .rules
        .as_ref()
        .map(serde_json::to_string)
        .transpose()?;
    let kind = playlist_kind_as_str(&payload.kind);
    let id = sqlx::query(
        r#"
        INSERT INTO playlists (name, kind, description, rules_json, created_at, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?5)
        RETURNING id
        "#,
    )
    .bind(name)
    .bind(kind)
    .bind(
        payload
            .description
            .as_deref()
            .filter(|value| !value.trim().is_empty()),
    )
    .bind(rules_json.as_deref())
    .bind(&now)
    .fetch_one(pool)
    .await?
    .try_get::<i64, _>("id")?;

    playlist_detail(pool, id, include_max_tag_rating_as_favorite).await
}

pub async fn update_playlist(
    pool: &DbPool,
    playlist_id: i64,
    payload: UpdatePlaylist,
    include_max_tag_rating_as_favorite: bool,
) -> Result<PlaylistDetail> {
    let row = sqlx::query("SELECT name, description, rules_json FROM playlists WHERE id = ?1")
        .bind(playlist_id)
        .fetch_one(pool)
        .await?;
    let current_name: String = row.try_get("name")?;
    let name = payload
        .name
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(current_name.as_str())
        .to_string();
    let description = payload.description.or_else(|| {
        row.try_get::<Option<String>, _>("description")
            .ok()
            .flatten()
    });
    let rules_json = if let Some(rules) = payload.rules {
        Some(serde_json::to_string(&rules)?)
    } else {
        row.try_get("rules_json")?
    };
    let now = Utc::now().to_rfc3339();

    sqlx::query(
        r#"
        UPDATE playlists
        SET name = ?1, description = ?2, rules_json = ?3, updated_at = ?4
        WHERE id = ?5
        "#,
    )
    .bind(name)
    .bind(
        description
            .as_deref()
            .filter(|value| !value.trim().is_empty()),
    )
    .bind(rules_json.as_deref())
    .bind(now)
    .bind(playlist_id)
    .execute(pool)
    .await?;

    playlist_detail(pool, playlist_id, include_max_tag_rating_as_favorite).await
}

pub async fn delete_playlist(pool: &DbPool, playlist_id: i64) -> Result<()> {
    sqlx::query("DELETE FROM playlists WHERE id = ?1")
        .bind(playlist_id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn playlist_detail(
    pool: &DbPool,
    playlist_id: i64,
    include_max_tag_rating_as_favorite: bool,
) -> Result<PlaylistDetail> {
    let row = sqlx::query(
        r#"
        SELECT p.id, p.name, p.kind, p.description, p.rules_json, p.created_at, p.updated_at,
               COUNT(pi.id) AS track_count
        FROM playlists p
        LEFT JOIN playlist_items pi ON pi.playlist_id = p.id
        WHERE p.id = ?1
        GROUP BY p.id
        "#,
    )
    .bind(playlist_id)
    .fetch_one(pool)
    .await?;

    let kind_text: String = row.try_get("kind")?;
    let rules = parse_rules_json(row.try_get::<Option<String>, _>("rules_json")?.as_deref())?;
    let tracks = if kind_text == "smart" {
        smart_playlist_tracks(
            pool,
            rules.as_ref(),
            1000,
            0,
            include_max_tag_rating_as_favorite,
        )
        .await?
    } else {
        manual_playlist_tracks(pool, playlist_id).await?
    };
    let playlist = row_to_playlist_summary(row, tracks.len() as i64)?;

    Ok(PlaylistDetail {
        playlist,
        rules,
        tracks,
    })
}

pub async fn add_playlist_track(
    pool: &DbPool,
    playlist_id: i64,
    payload: PlaylistTrackMutation,
    include_max_tag_rating_as_favorite: bool,
) -> Result<PlaylistDetail> {
    ensure_manual_playlist(pool, playlist_id).await?;
    let position = if let Some(position) = payload.position {
        position.max(0)
    } else {
        next_playlist_position(pool, playlist_id).await?
    };
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT INTO playlist_items (playlist_id, position, track_id)
        VALUES (?1, ?2, ?3)
        "#,
    )
    .bind(playlist_id)
    .bind(position)
    .bind(payload.track_id)
    .execute(pool)
    .await?;
    sqlx::query("UPDATE playlists SET updated_at = ?1 WHERE id = ?2")
        .bind(now)
        .bind(playlist_id)
        .execute(pool)
        .await?;
    playlist_detail(pool, playlist_id, include_max_tag_rating_as_favorite).await
}

pub async fn remove_playlist_track(
    pool: &DbPool,
    playlist_id: i64,
    track_id: i64,
    include_max_tag_rating_as_favorite: bool,
) -> Result<PlaylistDetail> {
    ensure_manual_playlist(pool, playlist_id).await?;
    sqlx::query("DELETE FROM playlist_items WHERE playlist_id = ?1 AND track_id = ?2")
        .bind(playlist_id)
        .bind(track_id)
        .execute(pool)
        .await?;
    compact_playlist_positions(pool, playlist_id).await?;
    let now = Utc::now().to_rfc3339();
    sqlx::query("UPDATE playlists SET updated_at = ?1 WHERE id = ?2")
        .bind(now)
        .bind(playlist_id)
        .execute(pool)
        .await?;
    playlist_detail(pool, playlist_id, include_max_tag_rating_as_favorite).await
}

pub async fn set_track_favorite(
    pool: &DbPool,
    track_id: i64,
    payload: TrackFavoriteUpdate,
) -> Result<TrackDetail> {
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT INTO user_track_state (
            track_id, is_favorite, user_rating, rating_source,
            favorite_updated_at, rating_updated_at, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?5, ?5)
        ON CONFLICT(track_id) DO UPDATE SET
            is_favorite = excluded.is_favorite,
            user_rating = COALESCE(excluded.user_rating, user_track_state.user_rating),
            rating_source = COALESCE(excluded.rating_source, user_track_state.rating_source),
            favorite_updated_at = excluded.favorite_updated_at,
            rating_updated_at = COALESCE(excluded.rating_updated_at, user_track_state.rating_updated_at),
            updated_at = excluded.updated_at
        "#,
    )
    .bind(track_id)
    .bind(if payload.is_favorite { 1_i64 } else { 0_i64 })
    .bind(payload.user_rating)
    .bind(payload.user_rating.map(|_| "user"))
    .bind(&now)
    .bind(payload.user_rating.map(|_| now.clone()))
    .execute(pool)
    .await?;

    track_detail(pool, track_id).await
}

pub async fn update_track_tag_rating(
    pool: &DbPool,
    track_id: i64,
    rating: i64,
    scale: i64,
) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        UPDATE tracks
        SET tag_rating = ?1, tag_rating_scale = ?2, updated_at = ?3
        WHERE id = ?4
        "#,
    )
    .bind(rating)
    .bind(scale)
    .bind(now)
    .bind(track_id)
    .execute(pool)
    .await?;
    rebuild_track_search_row(pool, track_id).await?;
    Ok(())
}

pub async fn scan_problems(pool: &DbPool, limit: u32, offset: u32) -> Result<Vec<ScanProblem>> {
    let rows = sqlx::query(
        r#"
        SELECT id AS file_id, path, scan_status, scan_message, updated_at
        FROM files
        WHERE scan_status != 'ok' AND deleted_at IS NULL
        ORDER BY updated_at DESC
        LIMIT ?1 OFFSET ?2
        "#,
    )
    .bind(limit as i64)
    .bind(offset as i64)
    .fetch_all(pool)
    .await?;

    rows.into_iter()
        .map(|row| {
            Ok(ScanProblem {
                file_id: row.try_get("file_id")?,
                path: row.try_get("path")?,
                scan_status: row.try_get("scan_status")?,
                message: row.try_get("scan_message")?,
                updated_at: parse_datetime(row.try_get::<String, _>("updated_at")?)?,
            })
        })
        .collect()
}

pub async fn record_playback_event(
    pool: &DbPool,
    event: PlaybackEventIngest,
) -> Result<PlaybackEvent> {
    let now = Utc::now().to_rfc3339();
    let position_ms = event.position_ms.map(|value| value as i64);
    let id = sqlx::query(
        r#"
        INSERT INTO playback_events (
            zone_id, event_type, track_id, track_title, position_ms,
            related_zone_id, reason, created_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        RETURNING id
        "#,
    )
    .bind(&event.zone_id)
    .bind(&event.event_type)
    .bind(event.track_id)
    .bind(&event.track_title)
    .bind(position_ms)
    .bind(&event.related_zone_id)
    .bind(&event.reason)
    .bind(&now)
    .fetch_one(pool)
    .await?
    .try_get::<i64, _>("id")?;

    get_playback_event(pool, id).await
}

pub async fn start_playback_session(
    pool: &DbPool,
    zone_id: &str,
    track_id: i64,
    track_title: &str,
    start_position_ms: u64,
) -> Result<PlaybackSession> {
    let now = Utc::now().to_rfc3339();
    let id = sqlx::query(
        r#"
        INSERT INTO playback_sessions (
            zone_id, track_id, track_title, started_at, start_position_ms,
            created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?4, ?4)
        RETURNING id
        "#,
    )
    .bind(zone_id)
    .bind(track_id)
    .bind(track_title)
    .bind(&now)
    .bind(start_position_ms as i64)
    .fetch_one(pool)
    .await?
    .try_get::<i64, _>("id")?;

    get_playback_session(pool, id).await
}

pub async fn update_open_playback_session_position(
    pool: &DbPool,
    zone_id: &str,
    position_ms: u64,
) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        UPDATE playback_sessions
        SET played_ms = MAX(?1 - start_position_ms, 0), updated_at = ?2
        WHERE id = (
            SELECT id FROM playback_sessions
            WHERE zone_id = ?3 AND ended_at IS NULL
            ORDER BY started_at DESC
            LIMIT 1
        )
        "#,
    )
    .bind(position_ms as i64)
    .bind(now)
    .bind(zone_id)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn finish_open_playback_session(
    pool: &DbPool,
    zone_id: &str,
    end_position_ms: u64,
    reason: &str,
) -> Result<Option<PlaybackSession>> {
    let Some(id) = open_playback_session_id(pool, zone_id).await? else {
        return Ok(None);
    };
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        UPDATE playback_sessions
        SET ended_at = ?1,
            end_position_ms = ?2,
            end_reason = ?3,
            played_ms = MAX(?2 - start_position_ms, 0),
            updated_at = ?1
        WHERE id = ?4
        "#,
    )
    .bind(&now)
    .bind(end_position_ms as i64)
    .bind(reason)
    .bind(id)
    .execute(pool)
    .await?;

    Ok(Some(get_playback_session(pool, id).await?))
}

pub async fn list_playback_events(
    pool: &DbPool,
    limit: u32,
    offset: u32,
    from: Option<String>,
    to: Option<String>,
) -> Result<Vec<PlaybackEvent>> {
    let rows = sqlx::query(
        r#"
        SELECT id, zone_id, event_type, track_id, track_title, position_ms,
               related_zone_id, reason, created_at
        FROM playback_events
        WHERE (?1 IS NULL OR created_at >= ?1)
          AND (?2 IS NULL OR created_at < ?2)
        ORDER BY created_at DESC, id DESC
        LIMIT ?3 OFFSET ?4
        "#,
    )
    .bind(from)
    .bind(to)
    .bind(limit as i64)
    .bind(offset as i64)
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_playback_event).collect()
}

pub async fn list_playback_sessions(
    pool: &DbPool,
    limit: u32,
    offset: u32,
    from: Option<String>,
    to: Option<String>,
) -> Result<Vec<PlaybackSession>> {
    let rows = sqlx::query(
        r#"
        SELECT id, zone_id, track_id, track_title, started_at, start_position_ms,
               ended_at, end_position_ms, end_reason, played_ms
        FROM playback_sessions
        WHERE (?1 IS NULL OR started_at >= ?1)
          AND (?2 IS NULL OR started_at < ?2)
        ORDER BY started_at DESC, id DESC
        LIMIT ?3 OFFSET ?4
        "#,
    )
    .bind(from)
    .bind(to)
    .bind(limit as i64)
    .bind(offset as i64)
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_playback_session).collect()
}

pub async fn playback_stats(
    pool: &DbPool,
    from: Option<String>,
    to: Option<String>,
    top_limit: u32,
) -> Result<PlaybackStats> {
    let total_events = sqlx::query(
        r#"
        SELECT COUNT(*) AS count
        FROM playback_events
        WHERE (?1 IS NULL OR created_at >= ?1)
          AND (?2 IS NULL OR created_at < ?2)
        "#,
    )
    .bind(from.as_deref())
    .bind(to.as_deref())
    .fetch_one(pool)
    .await?
    .try_get::<i64, _>("count")?;

    let session_row = sqlx::query(
        r#"
        SELECT
            COUNT(*) AS total_sessions,
            COALESCE(SUM(played_ms), 0) AS total_played_ms,
            SUM(CASE WHEN end_reason = 'completed' THEN 1 ELSE 0 END) AS completed_sessions,
            SUM(CASE WHEN ended_at IS NOT NULL AND end_reason != 'completed' THEN 1 ELSE 0 END) AS interrupted_sessions
        FROM playback_sessions
        WHERE (?1 IS NULL OR started_at >= ?1)
          AND (?2 IS NULL OR started_at < ?2)
        "#,
    )
    .bind(from.as_deref())
    .bind(to.as_deref())
    .fetch_one(pool)
    .await?;

    let top_rows = sqlx::query(
        r#"
        SELECT
            s.track_id,
            COALESCE(t.title, s.track_title) AS title,
            COALESCE(GROUP_CONCAT(DISTINCT ar.name), NULL) AS artist_display,
            al.title AS album_title,
            COUNT(*) AS play_count,
            COALESCE(SUM(s.played_ms), 0) AS total_played_ms,
            MAX(s.started_at) AS last_played_at
        FROM playback_sessions s
        LEFT JOIN tracks t ON t.id = s.track_id
        LEFT JOIN albums al ON al.id = t.album_id
        LEFT JOIN track_artists ta ON ta.track_id = t.id AND ta.role = 'primary'
        LEFT JOIN artists ar ON ar.id = ta.artist_id
        WHERE (?1 IS NULL OR s.started_at >= ?1)
          AND (?2 IS NULL OR s.started_at < ?2)
        GROUP BY s.track_id
        ORDER BY total_played_ms DESC, play_count DESC
        LIMIT ?3
        "#,
    )
    .bind(from.as_deref())
    .bind(to.as_deref())
    .bind(top_limit.clamp(1, 100) as i64)
    .fetch_all(pool)
    .await?;

    Ok(PlaybackStats {
        total_events,
        total_sessions: session_row.try_get("total_sessions")?,
        total_played_ms: session_row.try_get::<i64, _>("total_played_ms")? as u64,
        completed_sessions: session_row
            .try_get::<Option<i64>, _>("completed_sessions")?
            .unwrap_or(0),
        interrupted_sessions: session_row
            .try_get::<Option<i64>, _>("interrupted_sessions")?
            .unwrap_or(0),
        top_tracks: top_rows
            .into_iter()
            .map(row_to_track_playback_stat)
            .collect::<Result<_>>()?,
    })
}

pub async fn list_zones(pool: &DbPool) -> Result<Vec<protocol::ZoneSummary>> {
    let rows = sqlx::query("SELECT id, name, output_id, state, volume FROM zones ORDER BY name")
        .fetch_all(pool)
        .await?;
    rows.into_iter()
        .map(|row| {
            let state = match row.try_get::<String, _>("state")?.as_str() {
                "playing" => protocol::PlaybackTransportState::Playing,
                "paused" => protocol::PlaybackTransportState::Paused,
                _ => protocol::PlaybackTransportState::Stopped,
            };
            Ok(protocol::ZoneSummary {
                id: row.try_get("id")?,
                name: row.try_get("name")?,
                system_name: row.try_get("name")?,
                alias: None,
                output_id: row.try_get("output_id")?,
                state,
                volume: row.try_get::<f64, _>("volume")? as f32,
                muted: false,
                track_id: None,
                track_title: None,
                position_ms: 0,
                is_online: true,
                is_remote: false,
                node_id: Some("core".to_string()),
                node_name: Some("Core local".to_string()),
            })
        })
        .collect()
}

pub async fn list_zone_aliases(pool: &DbPool) -> Result<HashMap<String, String>> {
    let rows = sqlx::query("SELECT zone_id, alias FROM zone_aliases")
        .fetch_all(pool)
        .await?;

    rows.into_iter()
        .map(|row| Ok((row.try_get("zone_id")?, row.try_get("alias")?)))
        .collect()
}

pub async fn set_zone_alias(
    pool: &DbPool,
    zone_id: &str,
    alias: Option<&str>,
) -> Result<Option<String>> {
    let cleaned = alias
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned);
    let now = Utc::now().to_rfc3339();

    if let Some(alias) = cleaned {
        sqlx::query(
            r#"
            INSERT INTO zone_aliases (zone_id, alias, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?3)
            ON CONFLICT(zone_id) DO UPDATE SET
                alias = excluded.alias,
                updated_at = excluded.updated_at
            "#,
        )
        .bind(zone_id)
        .bind(&alias)
        .bind(&now)
        .execute(pool)
        .await?;
        Ok(Some(alias))
    } else {
        sqlx::query("DELETE FROM zone_aliases WHERE zone_id = ?1")
            .bind(zone_id)
            .execute(pool)
            .await?;
        Ok(None)
    }
}

pub async fn set_zone_state(pool: &DbPool, zone_id: &str, state: &str) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    sqlx::query("UPDATE zones SET state = ?1, updated_at = ?2 WHERE id = ?3")
        .bind(state)
        .bind(now)
        .bind(zone_id)
        .execute(pool)
        .await?;
    Ok(())
}

fn row_to_library_root(row: sqlx::sqlite::SqliteRow) -> Result<LibraryRoot> {
    Ok(LibraryRoot {
        id: row.try_get("id")?,
        path: row.try_get("path")?,
        enabled: row.try_get::<i64, _>("enabled")? != 0,
        created_at: parse_datetime(row.try_get::<String, _>("created_at")?)?,
        updated_at: parse_datetime(row.try_get::<String, _>("updated_at")?)?,
    })
}

fn row_to_album(row: sqlx::sqlite::SqliteRow) -> Result<AlbumSummary> {
    Ok(AlbumSummary {
        id: row.try_get("id")?,
        title: row.try_get("title")?,
        album_artist_display: row.try_get("album_artist_display")?,
        date: row.try_get("date")?,
        year: row.try_get("year")?,
        total_discs: row.try_get("total_discs")?,
        track_count: row.try_get("track_count")?,
        cover_asset_id: row.try_get("cover_asset_id")?,
    })
}

fn row_to_artist(row: sqlx::sqlite::SqliteRow) -> Result<ArtistSummary> {
    Ok(ArtistSummary {
        id: row.try_get("id")?,
        name: row.try_get("name")?,
        sort_name: row.try_get("sort_name")?,
        track_count: row.try_get("track_count")?,
        album_count: row.try_get("album_count")?,
        artwork_revision: row.try_get("artwork_revision")?,
        has_artwork: row.try_get::<i64, _>("has_artwork")? != 0,
    })
}

fn row_to_track(row: sqlx::sqlite::SqliteRow) -> Result<TrackSummary> {
    Ok(TrackSummary {
        id: row.try_get("id")?,
        file_id: row.try_get("file_id")?,
        album_id: row.try_get("album_id")?,
        title: row.try_get("title")?,
        artist_display: row.try_get("artist_display")?,
        album_title: row.try_get("album_title")?,
        disc_number: row.try_get("disc_number")?,
        track_number: row.try_get("track_number")?,
        duration_ms: row.try_get("duration_ms")?,
        year: row.try_get("year")?,
        cover_asset_id: row.try_get("cover_asset_id")?,
        is_favorite: row.try_get::<i64, _>("is_favorite")? != 0,
        user_rating: row.try_get("user_rating")?,
        tag_rating: row.try_get("tag_rating")?,
        tag_rating_scale: row.try_get("tag_rating_scale")?,
        effective_rating: row.try_get("effective_rating")?,
        size_bytes: row.try_get("size_bytes")?,
        added_at: parse_datetime(row.try_get::<String, _>("added_at")?)?,
        play_count: row.try_get("play_count")?,
    })
}

fn row_to_playlist_summary(
    row: sqlx::sqlite::SqliteRow,
    track_count: i64,
) -> Result<PlaylistSummary> {
    Ok(PlaylistSummary {
        id: row.try_get("id")?,
        name: row.try_get("name")?,
        kind: parse_playlist_kind(&row.try_get::<String, _>("kind")?),
        description: row.try_get("description")?,
        track_count,
        created_at: parse_datetime(row.try_get::<String, _>("created_at")?)?,
        updated_at: parse_datetime(row.try_get::<String, _>("updated_at")?)?,
    })
}

async fn manual_playlist_tracks(pool: &DbPool, playlist_id: i64) -> Result<Vec<TrackSummary>> {
    let rows = sqlx::query(
        track_select_sql(
            r#"
            JOIN playlist_items pi ON pi.track_id = t.id
            WHERE pi.playlist_id = ?1
            GROUP BY t.id, pi.id
            ORDER BY pi.position, pi.id
            "#,
        )
        .as_str(),
    )
    .bind(playlist_id)
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_track).collect()
}

async fn ensure_manual_playlist(pool: &DbPool, playlist_id: i64) -> Result<()> {
    let kind: String = sqlx::query("SELECT kind FROM playlists WHERE id = ?1")
        .bind(playlist_id)
        .fetch_one(pool)
        .await?
        .try_get("kind")?;
    if kind != "manual" {
        anyhow::bail!("smart playlists are rule based and cannot be edited manually");
    }
    Ok(())
}

async fn next_playlist_position(pool: &DbPool, playlist_id: i64) -> Result<i64> {
    let position = sqlx::query(
        "SELECT COALESCE(MAX(position), -1) + 1 AS position FROM playlist_items WHERE playlist_id = ?1",
    )
    .bind(playlist_id)
    .fetch_one(pool)
    .await?
    .try_get("position")?;
    Ok(position)
}

async fn compact_playlist_positions(pool: &DbPool, playlist_id: i64) -> Result<()> {
    let item_ids =
        sqlx::query("SELECT id FROM playlist_items WHERE playlist_id = ?1 ORDER BY position, id")
            .bind(playlist_id)
            .fetch_all(pool)
            .await?
            .into_iter()
            .map(|row| row.try_get::<i64, _>("id"))
            .collect::<Result<Vec<_>, _>>()?;

    for (position, item_id) in item_ids.into_iter().enumerate() {
        sqlx::query("UPDATE playlist_items SET position = ?1 WHERE id = ?2")
            .bind(position as i64)
            .bind(item_id)
            .execute(pool)
            .await?;
    }
    Ok(())
}

async fn smart_playlist_tracks(
    pool: &DbPool,
    rules: Option<&Value>,
    limit: u32,
    offset: u32,
    include_max_tag_rating_as_favorite: bool,
) -> Result<Vec<TrackSummary>> {
    let mut query = QueryBuilder::<Sqlite>::new("");
    push_track_select_builder(&mut query);
    push_smart_where(&mut query, rules, include_max_tag_rating_as_favorite);
    query.push(" GROUP BY t.id ORDER BY t.title COLLATE NOCASE LIMIT ");
    query.push_bind(limit.clamp(1, 5000) as i64);
    query.push(" OFFSET ");
    query.push_bind(offset as i64);

    let rows = query.build().fetch_all(pool).await?;
    rows.into_iter().map(row_to_track).collect()
}

async fn smart_playlist_track_count(
    pool: &DbPool,
    rules: Option<&Value>,
    include_max_tag_rating_as_favorite: bool,
) -> Result<i64> {
    let mut query = QueryBuilder::<Sqlite>::new("SELECT COUNT(DISTINCT t.id) AS count");
    push_track_from_joins(&mut query);
    push_smart_where(&mut query, rules, include_max_tag_rating_as_favorite);
    Ok(query
        .build()
        .fetch_one(pool)
        .await?
        .try_get::<i64, _>("count")?)
}

fn push_track_select_builder(query: &mut QueryBuilder<'_, Sqlite>) {
    query.push(
        r#"
        SELECT
            t.id, t.file_id, t.album_id, t.title,
            COALESCE(GROUP_CONCAT(DISTINCT ar.name), NULL) AS artist_display,
            al.title AS album_title,
            t.disc_number, t.track_number, t.duration_ms, t.year, t.cover_asset_id,
            COALESCE(uts.is_favorite, 0) AS is_favorite,
            uts.user_rating,
            t.tag_rating,
            t.tag_rating_scale,
            COALESCE(
                uts.user_rating,
                CASE
                    WHEN t.tag_rating IS NOT NULL
                     AND t.tag_rating_scale IS NOT NULL
                     AND t.tag_rating_scale > 0
                    THEN CAST(ROUND(t.tag_rating * 100.0 / t.tag_rating_scale) AS INTEGER)
                    ELSE NULL
                END
            ) AS effective_rating,
            f.size_bytes AS size_bytes,
            f.created_at AS added_at,
            (
                SELECT COUNT(*)
                FROM playback_sessions ps
                WHERE ps.track_id = t.id
            ) AS play_count
        "#,
    );
    push_track_from_joins(query);
}

fn push_track_from_joins(query: &mut QueryBuilder<'_, Sqlite>) {
    query.push(
        r#"
        FROM tracks t
        LEFT JOIN albums al ON al.id = t.album_id
        LEFT JOIN track_artists ta ON ta.track_id = t.id AND ta.role = 'primary'
        LEFT JOIN artists ar ON ar.id = ta.artist_id
        LEFT JOIN user_track_state uts ON uts.track_id = t.id
        LEFT JOIN files f ON f.id = t.file_id
        "#,
    );
}

fn push_smart_where(
    query: &mut QueryBuilder<'_, Sqlite>,
    rules: Option<&Value>,
    include_max_tag_rating_as_favorite: bool,
) {
    let rule_values = smart_rule_values(rules);
    if rule_values.is_empty() {
        return;
    }

    let match_any = smart_match_any(rules);
    query.push(" WHERE ");
    query.push(if match_any { "0 = 1" } else { "1 = 1" });
    for rule in rule_values {
        query.push(if match_any { " OR " } else { " AND " });
        if !push_smart_rule(query, rule, include_max_tag_rating_as_favorite) {
            query.push(if match_any { "0 = 1" } else { "1 = 1" });
        }
    }
}

fn smart_rule_values(rules: Option<&Value>) -> Vec<&Value> {
    let Some(rules) = rules else {
        return Vec::new();
    };
    if let Some(array) = rules.as_array() {
        return array.iter().collect();
    }
    if let Some(array) = rules.get("rules").and_then(Value::as_array) {
        return array.iter().collect();
    }
    if rules.is_object() {
        return vec![rules];
    }
    Vec::new()
}

fn smart_match_any(rules: Option<&Value>) -> bool {
    rules
        .and_then(|value| value.get("match").or_else(|| value.get("mode")))
        .and_then(Value::as_str)
        .map(|value| matches!(value.to_ascii_lowercase().as_str(), "any" | "or"))
        .unwrap_or(false)
}

fn push_smart_rule(
    query: &mut QueryBuilder<'_, Sqlite>,
    rule: &Value,
    include_max_tag_rating_as_favorite: bool,
) -> bool {
    let field = rule
        .get("field")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    let operator = rule
        .get("op")
        .or_else(|| rule.get("operator"))
        .and_then(Value::as_str)
        .unwrap_or("contains")
        .to_ascii_lowercase();
    let value = rule.get("value").unwrap_or(&Value::Null);

    match field.as_str() {
        "title" | "track" => push_text_rule(query, "t.title", &operator, value),
        "album" => push_text_rule(query, "al.title", &operator, value),
        "album_artist" => push_text_rule(query, "al.album_artist_display", &operator, value),
        "artist" => push_exists_text_rule(
            query,
            r#"EXISTS (
                SELECT 1
                FROM track_artists ta2
                JOIN artists ar2 ON ar2.id = ta2.artist_id
                WHERE ta2.track_id = t.id AND ta2.role = 'primary' AND "#,
            "ar2.name",
            &operator,
            value,
        ),
        "composer" => push_exists_text_rule(
            query,
            r#"EXISTS (
                SELECT 1
                FROM track_artists ta2
                JOIN artists ar2 ON ar2.id = ta2.artist_id
                WHERE ta2.track_id = t.id AND ta2.role = 'composer' AND "#,
            "ar2.name",
            &operator,
            value,
        ),
        "lyricist" | "writer" => push_exists_text_rule(
            query,
            r#"EXISTS (
                SELECT 1
                FROM track_artists ta2
                JOIN artists ar2 ON ar2.id = ta2.artist_id
                WHERE ta2.track_id = t.id AND ta2.role = 'lyricist' AND "#,
            "ar2.name",
            &operator,
            value,
        ),
        "genre" => push_exists_text_rule(
            query,
            r#"EXISTS (
                SELECT 1
                FROM track_genres tg2
                JOIN genres g2 ON g2.id = tg2.genre_id
                WHERE tg2.track_id = t.id AND "#,
            "g2.name",
            &operator,
            value,
        ),
        "extension" | "format" => push_text_rule(query, "f.extension", &operator, value),
        "path" | "file" => push_text_rule(query, "f.path", &operator, value),
        "year" => push_number_rule(query, "t.year", &operator, value),
        "duration_ms" | "duration" => push_number_rule(query, "t.duration_ms", &operator, value),
        "rating" | "effective_rating" => {
            push_number_rule(query, effective_rating_expr(), &operator, value)
        }
        "tag_rating" => push_number_rule(query, "t.tag_rating", &operator, value),
        "favorite" | "favourite" => {
            let expression = if include_max_tag_rating_as_favorite {
                favorite_with_tag_rating_expr()
            } else {
                "COALESCE(uts.is_favorite, 0)"
            };
            push_bool_rule(query, expression, value)
        }
        _ => false,
    }
}

fn favorite_with_tag_rating_expr() -> &'static str {
    r#"
    (
        COALESCE(uts.is_favorite, 0) = 1
        OR (
            t.tag_rating IS NOT NULL
            AND t.tag_rating_scale IS NOT NULL
            AND t.tag_rating_scale > 0
            AND t.tag_rating >= t.tag_rating_scale
        )
    )
    "#
}

fn push_exists_text_rule(
    query: &mut QueryBuilder<'_, Sqlite>,
    prefix: &str,
    column: &str,
    operator: &str,
    value: &Value,
) -> bool {
    let Some(text) = value_to_string(value) else {
        return false;
    };
    query.push(prefix);
    push_text_condition(query, column, operator, &text);
    query.push(")");
    true
}

fn push_text_rule(
    query: &mut QueryBuilder<'_, Sqlite>,
    column: &str,
    operator: &str,
    value: &Value,
) -> bool {
    let Some(text) = value_to_string(value) else {
        return false;
    };
    push_text_condition(query, column, operator, &text);
    true
}

fn push_text_condition(
    query: &mut QueryBuilder<'_, Sqlite>,
    column: &str,
    operator: &str,
    value: &str,
) {
    let normalized = value.to_ascii_lowercase();
    query.push("LOWER(COALESCE(");
    query.push(column);
    query.push(", '')) ");
    match operator {
        "equals" | "is" | "=" | "==" => {
            query.push("= ");
            query.push_bind(normalized);
        }
        "not_equals" | "!=" => {
            query.push("!= ");
            query.push_bind(normalized);
        }
        "starts_with" => {
            query.push("LIKE ");
            query.push_bind(format!("{normalized}%"));
        }
        "ends_with" => {
            query.push("LIKE ");
            query.push_bind(format!("%{normalized}"));
        }
        "not_contains" => {
            query.push("NOT LIKE ");
            query.push_bind(format!("%{normalized}%"));
        }
        _ => {
            query.push("LIKE ");
            query.push_bind(format!("%{normalized}%"));
        }
    }
}

fn push_number_rule(
    query: &mut QueryBuilder<'_, Sqlite>,
    expression: &str,
    operator: &str,
    value: &Value,
) -> bool {
    let Some(number) = value_to_i64(value) else {
        return false;
    };
    query.push("(");
    query.push(expression);
    query.push(") ");
    match operator {
        "gt" | ">" => query.push("> "),
        "gte" | ">=" => query.push(">= "),
        "lt" | "<" => query.push("< "),
        "lte" | "<=" => query.push("<= "),
        "not_equals" | "!=" => query.push("!= "),
        _ => query.push("= "),
    };
    query.push_bind(number);
    true
}

fn push_bool_rule(query: &mut QueryBuilder<'_, Sqlite>, expression: &str, value: &Value) -> bool {
    let Some(value) = value_to_bool(value) else {
        return false;
    };
    query.push("(");
    query.push(expression);
    query.push(") = ");
    query.push_bind(if value { 1_i64 } else { 0_i64 });
    true
}

fn value_to_string(value: &Value) -> Option<String> {
    match value {
        Value::String(value) => Some(value.trim().to_string()).filter(|value| !value.is_empty()),
        Value::Number(value) => Some(value.to_string()),
        Value::Bool(value) => Some(value.to_string()),
        _ => None,
    }
}

fn value_to_i64(value: &Value) -> Option<i64> {
    match value {
        Value::Number(value) => value
            .as_i64()
            .or_else(|| value.as_f64().map(|value| value as i64)),
        Value::String(value) => value.trim().parse::<i64>().ok(),
        _ => None,
    }
}

fn value_to_bool(value: &Value) -> Option<bool> {
    match value {
        Value::Bool(value) => Some(*value),
        Value::Number(value) => Some(value.as_i64()? != 0),
        Value::String(value) => match value.trim().to_ascii_lowercase().as_str() {
            "true" | "yes" | "1" | "favorite" | "favourite" => Some(true),
            "false" | "no" | "0" => Some(false),
            _ => None,
        },
        _ => None,
    }
}

fn parse_rules_json(value: Option<&str>) -> Result<Option<Value>> {
    value
        .filter(|value| !value.trim().is_empty())
        .map(serde_json::from_str)
        .transpose()
        .map_err(Into::into)
}

fn playlist_kind_as_str(kind: &PlaylistKind) -> &'static str {
    match kind {
        PlaylistKind::Manual => "manual",
        PlaylistKind::Smart => "smart",
    }
}

fn parse_playlist_kind(value: &str) -> PlaylistKind {
    if value == "smart" {
        PlaylistKind::Smart
    } else {
        PlaylistKind::Manual
    }
}

fn effective_rating_expr() -> &'static str {
    r#"
    COALESCE(
        uts.user_rating,
        CASE
            WHEN t.tag_rating IS NOT NULL
             AND t.tag_rating_scale IS NOT NULL
             AND t.tag_rating_scale > 0
            THEN CAST(ROUND(t.tag_rating * 100.0 / t.tag_rating_scale) AS INTEGER)
            ELSE NULL
        END
    )
    "#
}

fn row_to_playback_event(row: sqlx::sqlite::SqliteRow) -> Result<PlaybackEvent> {
    Ok(PlaybackEvent {
        id: row.try_get("id")?,
        zone_id: row.try_get("zone_id")?,
        event_type: row.try_get("event_type")?,
        track_id: row.try_get("track_id")?,
        track_title: row.try_get("track_title")?,
        position_ms: row
            .try_get::<Option<i64>, _>("position_ms")?
            .map(|value| value as u64),
        related_zone_id: row.try_get("related_zone_id")?,
        reason: row.try_get("reason")?,
        created_at: parse_datetime(row.try_get::<String, _>("created_at")?)?,
    })
}

fn row_to_playback_session(row: sqlx::sqlite::SqliteRow) -> Result<PlaybackSession> {
    Ok(PlaybackSession {
        id: row.try_get("id")?,
        zone_id: row.try_get("zone_id")?,
        track_id: row.try_get("track_id")?,
        track_title: row.try_get("track_title")?,
        started_at: parse_datetime(row.try_get::<String, _>("started_at")?)?,
        start_position_ms: row.try_get::<i64, _>("start_position_ms")? as u64,
        ended_at: row
            .try_get::<Option<String>, _>("ended_at")?
            .map(parse_datetime)
            .transpose()?,
        end_position_ms: row
            .try_get::<Option<i64>, _>("end_position_ms")?
            .map(|value| value as u64),
        end_reason: row.try_get("end_reason")?,
        played_ms: row.try_get::<i64, _>("played_ms")? as u64,
    })
}

fn row_to_track_playback_stat(row: sqlx::sqlite::SqliteRow) -> Result<TrackPlaybackStat> {
    Ok(TrackPlaybackStat {
        track_id: row.try_get("track_id")?,
        title: row.try_get("title")?,
        artist_display: row.try_get("artist_display")?,
        album_title: row.try_get("album_title")?,
        play_count: row.try_get("play_count")?,
        total_played_ms: row.try_get::<i64, _>("total_played_ms")? as u64,
        last_played_at: row
            .try_get::<Option<String>, _>("last_played_at")?
            .map(parse_datetime)
            .transpose()?,
    })
}

async fn get_playback_event(pool: &DbPool, id: i64) -> Result<PlaybackEvent> {
    let row = sqlx::query(
        r#"
        SELECT id, zone_id, event_type, track_id, track_title, position_ms,
               related_zone_id, reason, created_at
        FROM playback_events
        WHERE id = ?1
        "#,
    )
    .bind(id)
    .fetch_one(pool)
    .await?;
    row_to_playback_event(row)
}

async fn get_playback_session(pool: &DbPool, id: i64) -> Result<PlaybackSession> {
    let row = sqlx::query(
        r#"
        SELECT id, zone_id, track_id, track_title, started_at, start_position_ms,
               ended_at, end_position_ms, end_reason, played_ms
        FROM playback_sessions
        WHERE id = ?1
        "#,
    )
    .bind(id)
    .fetch_one(pool)
    .await?;
    row_to_playback_session(row)
}

async fn open_playback_session_id(pool: &DbPool, zone_id: &str) -> Result<Option<i64>> {
    Ok(sqlx::query(
        r#"
        SELECT id
        FROM playback_sessions
        WHERE zone_id = ?1 AND ended_at IS NULL
        ORDER BY started_at DESC
        LIMIT 1
        "#,
    )
    .bind(zone_id)
    .fetch_optional(pool)
    .await?
    .map(|row| row.try_get::<i64, _>("id"))
    .transpose()?)
}

fn track_select_sql(tail: &str) -> String {
    track_select_sql_extra("", tail)
}

fn track_select_sql_extra(extra_select: &str, tail: &str) -> String {
    format!(
        r#"
        SELECT
            {extra_select}
            t.id, t.file_id, t.album_id, t.title,
            COALESCE(GROUP_CONCAT(DISTINCT ar.name), NULL) AS artist_display,
            al.title AS album_title,
            t.disc_number, t.track_number, t.duration_ms, t.year, t.cover_asset_id,
            COALESCE(uts.is_favorite, 0) AS is_favorite,
            uts.user_rating,
            t.tag_rating,
            t.tag_rating_scale,
            COALESCE(
                uts.user_rating,
                CASE
                    WHEN t.tag_rating IS NOT NULL
                     AND t.tag_rating_scale IS NOT NULL
                     AND t.tag_rating_scale > 0
                    THEN CAST(ROUND(t.tag_rating * 100.0 / t.tag_rating_scale) AS INTEGER)
                    ELSE NULL
                END
            ) AS effective_rating,
            f.size_bytes AS size_bytes,
            f.created_at AS added_at,
            (
                SELECT COUNT(*)
                FROM playback_sessions ps
                WHERE ps.track_id = t.id
            ) AS play_count
        FROM tracks t
        JOIN files f ON f.id = t.file_id
        LEFT JOIN albums al ON al.id = t.album_id
        LEFT JOIN track_artists ta ON ta.track_id = t.id AND ta.role = 'primary'
        LEFT JOIN artists ar ON ar.id = ta.artist_id
        LEFT JOIN user_track_state uts ON uts.track_id = t.id
        {tail}
        "#
    )
}

fn parse_datetime(value: String) -> Result<DateTime<Utc>> {
    if let Ok(value) = DateTime::parse_from_rfc3339(&value) {
        return Ok(value.with_timezone(&Utc));
    }
    Ok(Utc::now())
}

pub fn normalize_path(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

pub fn normalize_text(value: &str) -> String {
    value.trim().to_lowercase()
}

fn album_key(
    album_artist: &str,
    album_title: &str,
    year: Option<i64>,
    library_root_id: i64,
) -> String {
    format!(
        "{}\0{}\0{}\0{}",
        normalize_text(album_artist),
        normalize_text(album_title),
        year.map(|year| year.to_string()).unwrap_or_default(),
        library_root_id
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn test_pool() -> (DbPool, PathBuf) {
        let path =
            std::env::temp_dir().join(format!("intmusic-core-db-{}.sqlite", uuid::Uuid::new_v4()));
        let pool = connect(&path).await.expect("create test database");
        migrate(&pool).await.expect("migrate test database");
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            r#"
            INSERT INTO library_roots (id, path, enabled, created_at, updated_at)
            VALUES (1, '/music', 1, ?1, ?1)
            "#,
        )
        .bind(&now)
        .execute(&pool)
        .await
        .expect("insert root");
        for id in 1_i64..=3 {
            sqlx::query(
                r#"
                INSERT INTO files (
                    id, library_root_id, path, relative_path, extension,
                    size_bytes, modified_at, scan_status, created_at, updated_at
                )
                VALUES (?1, 1, ?2, ?3, 'flac', 1024, ?4, 'ready', ?4, ?4)
                "#,
            )
            .bind(id)
            .bind(format!("/music/{id}.flac"))
            .bind(format!("{id}.flac"))
            .bind(&now)
            .execute(&pool)
            .await
            .expect("insert file");
            sqlx::query(
                r#"
                INSERT INTO tracks (id, file_id, title, duration_ms, created_at, updated_at)
                VALUES (?1, ?1, ?2, 180000, ?3, ?3)
                "#,
            )
            .bind(id)
            .bind(format!("Track {id}"))
            .bind(&now)
            .execute(&pool)
            .await
            .expect("insert track");
        }
        (pool, path)
    }

    async fn close_test_pool(pool: DbPool, path: PathBuf) {
        pool.close().await;
        let _ = tokio::fs::remove_file(&path).await;
        let _ = tokio::fs::remove_file(path.with_extension("sqlite-shm")).await;
        let _ = tokio::fs::remove_file(path.with_extension("sqlite-wal")).await;
    }

    #[tokio::test]
    async fn client_sync_identity_and_cursor_are_durable() {
        let (pool, path) = test_pool().await;
        let first_server_id = sync_server_id(&pool).await.expect("server ID");
        assert_eq!(
            sync_server_id(&pool).await.expect("stable server ID"),
            first_server_id
        );
        let baseline = sync_cursor(&pool).await.expect("baseline cursor");
        assert!(baseline > 0);
        let first = append_sync_change(&pool, "tracks", "favorite updated")
            .await
            .expect("first change");
        let second = append_sync_change(&pool, "artists", "profile updated")
            .await
            .expect("second change");
        assert!(first > baseline);
        assert!(second > first);
        let changes = client_sync_changes(&pool, first, 50)
            .await
            .expect("changes after cursor");
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].cursor, second);
        assert_eq!(changes[0].scope, "artists");
        close_test_pool(pool, path).await;
    }

    async fn ingest_test_track(pool: &DbPool, filename: &str, album: &str, title: &str) -> i64 {
        let now = Utc::now().to_rfc3339();
        let file = FileIngest {
            library_root_id: 1,
            path: format!("/music/{filename}"),
            relative_path: filename.to_string(),
            extension: "flac".to_string(),
            size_bytes: 10_000,
            modified_at: now,
            quick_hash: Some(format!("quick-{filename}")),
            scan_status: "ok".to_string(),
            scan_message: None,
            codec: Some("flac".to_string()),
            sample_rate: Some(96_000),
            channels: Some(2),
            duration_ms: Some(240_000),
            bitrate: Some(2_400_000),
            bit_depth: Some(24),
        };
        let metadata = TrackIngest {
            title: title.to_string(),
            album: Some(album.to_string()),
            track_artists: vec!["Artist".to_string()],
            album_artists: vec!["Artist".to_string()],
            disc_number: Some(1),
            track_number: Some(1),
            duration_ms: Some(240_000),
            year: Some(2020),
            ..Default::default()
        };
        let file_id = upsert_scanned_file(pool, &file, Some(&metadata))
            .await
            .expect("ingest track");
        track_id_for_file(pool, file_id)
            .await
            .expect("find track")
            .expect("track exists")
    }

    #[tokio::test]
    async fn release_tracks_remain_in_each_album_when_recordings_are_related() {
        let (pool, path) = test_pool().await;
        let original_track_id =
            ingest_test_track(&pool, "original.flac", "Original Album", "Shared Song").await;
        let compilation_track_id =
            ingest_test_track(&pool, "compilation.flac", "Compilation", "Shared Song").await;

        let original = track_media_profile(&pool, original_track_id)
            .await
            .expect("load original media")
            .expect("original media exists");
        let compilation = track_media_profile(&pool, compilation_track_id)
            .await
            .expect("load compilation media")
            .expect("compilation media exists");
        assert_ne!(original.release_track_id, compilation.release_track_id);
        assert_ne!(original.recording.id, compilation.recording.id);
        assert_eq!(original.variants.len(), 1);
        assert_eq!(original.variants[0].replicas.len(), 1);
        assert_eq!(original.variants[0].replicas[0].device_name, "Core local");

        let candidates = recording_link_candidates(&pool, compilation_track_id, 10)
            .await
            .expect("load candidates");
        let original_candidate = candidates
            .iter()
            .find(|candidate| candidate.track_id == original_track_id)
            .expect("original is a candidate");
        assert!(original_candidate.confidence >= 0.9);
        assert!(!original_candidate.already_linked);

        // Confirming that both release tracks use the same recording changes only
        // their relationship; neither album row nor either release-track slot is
        // removed.
        let linked = link_track_to_recording(&pool, compilation_track_id, original_track_id)
            .await
            .expect("relate recording");
        assert_eq!(linked.recording.id, original.recording.id);
        assert_eq!(linked.related_release_tracks.len(), 2);

        let related = track_media_profile(&pool, original_track_id)
            .await
            .expect("reload related media")
            .expect("related media exists");
        assert_eq!(related.related_release_tracks.len(), 2);

        let original_album =
            album_detail(&pool, original.release.expect("release").album_id.unwrap())
                .await
                .expect("original album");
        let compilation_album = album_detail(
            &pool,
            compilation.release.expect("release").album_id.unwrap(),
        )
        .await
        .expect("compilation album");
        assert_eq!(original_album.tracks.len(), 1);
        assert_eq!(compilation_album.tracks.len(), 1);
        assert_eq!(original_album.tracks[0].id, original_track_id);
        assert_eq!(compilation_album.tracks[0].id, compilation_track_id);

        // A confirmed relationship remains shared after rescanning either file.
        ingest_test_track(&pool, "compilation.flac", "Compilation", "Shared Song").await;
        let rescanned = track_media_profile(&pool, compilation_track_id)
            .await
            .expect("load rescanned media")
            .expect("rescanned media exists");
        assert_eq!(rescanned.recording.id, original.recording.id);
        assert_eq!(rescanned.related_release_tracks.len(), 2);

        let detached = detach_track_recording(&pool, compilation_track_id)
            .await
            .expect("detach recording");
        assert_ne!(detached.recording.id, original.recording.id);
        assert_eq!(detached.related_release_tracks.len(), 1);
        let original_after_detach = track_media_profile(&pool, original_track_id)
            .await
            .expect("reload original")
            .expect("original exists");
        assert_eq!(original_after_detach.related_release_tracks.len(), 1);

        close_test_pool(pool, path).await;
    }

    #[tokio::test]
    async fn queue_mutations_keep_current_track_and_revision() {
        let (pool, path) = test_pool().await;
        let queue = replace_playback_queue(
            &pool,
            "zone-a",
            ReplacePlaybackQueue {
                track_ids: vec![1, 2, 3],
                start_index: Some(1),
                mode: Some(PlaybackMode::Sequential),
            },
        )
        .await
        .expect("replace queue");
        assert_eq!(queue.items.len(), 3);
        assert_eq!(queue.current_index, Some(1));
        assert_eq!(queue.items[1].track.id, 2);

        let moved = move_playback_queue_item(&pool, "zone-a", 1, 0)
            .await
            .expect("move queue item");
        assert!(moved.revision > queue.revision);
        assert_eq!(moved.items[0].track.id, 2);
        assert_eq!(moved.current_index, Some(0));

        let removed = remove_playback_queue_item(&pool, "zone-a", moved.items[2].id)
            .await
            .expect("remove queue item");
        assert_eq!(removed.items.len(), 2);
        assert_eq!(removed.items[0].track.id, 2);
        assert_eq!(removed.current_index, Some(0));

        close_test_pool(pool, path).await;
    }

    #[tokio::test]
    async fn stepping_and_volume_follow_persisted_zone_preferences() {
        let (pool, path) = test_pool().await;
        replace_playback_queue(
            &pool,
            "zone-b",
            ReplacePlaybackQueue {
                track_ids: vec![1, 2, 3],
                start_index: Some(0),
                mode: Some(PlaybackMode::RepeatAll),
            },
        )
        .await
        .expect("replace queue");

        let previous = step_playback_queue(&pool, "zone-b", true, false)
            .await
            .expect("step previous")
            .expect("repeat all wraps");
        assert_eq!(previous, 3);
        let next = step_playback_queue(&pool, "zone-b", false, false)
            .await
            .expect("step next")
            .expect("repeat all wraps forward");
        assert_eq!(next, 1);

        let volume = set_zone_volume(&pool, "zone-b", 1.7, Some(false))
            .await
            .expect("set volume");
        assert_eq!(volume.volume, 1.0);
        assert!(!volume.muted);
        let persisted = zone_volume(&pool, "zone-b").await.expect("get volume");
        assert_eq!(persisted.volume, 1.0);
        assert!(!persisted.muted);

        close_test_pool(pool, path).await;
    }

    #[tokio::test]
    async fn repairs_migration_checksums_changed_only_by_line_endings() {
        let path =
            std::env::temp_dir().join(format!("intmusic-core-db-{}.sqlite", uuid::Uuid::new_v4()));
        let pool = connect(&path).await.expect("create test database");
        migrate(&pool).await.expect("migrate test database");

        let migration = MIGRATOR
            .iter()
            .find(|migration| migration.version == 1)
            .expect("initial migration");
        let alternate_checksum = migration_line_ending_checksums(&migration.sql)
            .into_iter()
            .find(|checksum| checksum.as_slice() != migration.checksum.as_ref())
            .expect("alternate line-ending checksum");
        sqlx::query("UPDATE _sqlx_migrations SET checksum = ?1 WHERE version = 1")
            .bind(&alternate_checksum)
            .execute(&pool)
            .await
            .expect("replace migration checksum");

        migrate(&pool)
            .await
            .expect("repair line-ending migration checksum");

        let repaired_checksum: Vec<u8> =
            sqlx::query_scalar("SELECT checksum FROM _sqlx_migrations WHERE version = 1")
                .fetch_one(&pool)
                .await
                .expect("load repaired checksum");
        assert_eq!(repaired_checksum.as_slice(), migration.checksum.as_ref());

        close_test_pool(pool, path).await;
    }

    #[tokio::test]
    async fn rejects_genuinely_modified_migration_checksums() {
        let path =
            std::env::temp_dir().join(format!("intmusic-core-db-{}.sqlite", uuid::Uuid::new_v4()));
        let pool = connect(&path).await.expect("create test database");
        migrate(&pool).await.expect("migrate test database");

        sqlx::query("UPDATE _sqlx_migrations SET checksum = zeroblob(48) WHERE version = 1")
            .execute(&pool)
            .await
            .expect("replace migration checksum");

        let error = migrate(&pool)
            .await
            .expect_err("a genuinely different checksum must still fail");
        assert!(error
            .to_string()
            .contains("failed to run database migrations"));

        close_test_pool(pool, path).await;
    }

    #[tokio::test]
    async fn artist_profiles_and_five_region_visuals_round_trip() {
        let (pool, path) = test_pool().await;
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            r#"
            INSERT INTO artists (
                id, name, sort_name, normalized_name, created_at, updated_at
            )
            VALUES (1, 'Local Artist', NULL, 'local artist', ?1, ?1)
            "#,
        )
        .bind(&now)
        .execute(&pool)
        .await
        .expect("insert artist");

        update_artist_profile(
            &pool,
            1,
            &UpdateArtistProfile {
                display_name: Some("Display Artist".to_string()),
                musicbrainz_id: Some("20244d07-534f-4eff-b4d4-930878889970".to_string()),
                genres: vec!["Pop".to_string()],
                ..UpdateArtistProfile::default()
            },
        )
        .await
        .expect("save profile");
        let asset = add_artist_asset(
            &pool,
            1,
            NewArtistAsset {
                sha256: "test-sha",
                original_filename: "artist.png",
                storage_path: "/tmp/artist.png",
                mime_type: "image/png",
                width: 1000,
                height: 1000,
                byte_size: 1024,
                photo_type: "portrait",
            },
        )
        .await
        .expect("save asset");
        let regions = (0_u8..5)
            .map(|position| ArtistVisualRegion {
                position,
                asset_id: asset.id,
                crop_x: 0.0,
                crop_y: 0.0,
                crop_width: 1.0,
                crop_height: 1.0,
                focal_x: 0.5,
                focal_y: 0.5,
            })
            .collect::<Vec<_>>();
        let visual = save_artist_visual(
            &pool,
            1,
            "avatar",
            &UpdateArtistVisual {
                asset_id: Some(asset.id),
                template: "feature".to_string(),
                fit: "cover".to_string(),
                focal_x: 0.5,
                focal_y: 0.5,
                blur: 0.0,
                brightness: 1.0,
                regions: regions.clone(),
            },
        )
        .await
        .expect("save five-region visual");
        assert_eq!(visual.regions.len(), 5);

        let mut six_regions = regions;
        six_regions.push(ArtistVisualRegion {
            position: 5,
            asset_id: asset.id,
            crop_x: 0.0,
            crop_y: 0.0,
            crop_width: 1.0,
            crop_height: 1.0,
            focal_x: 0.5,
            focal_y: 0.5,
        });
        let error = save_artist_visual(
            &pool,
            1,
            "avatar",
            &UpdateArtistVisual {
                asset_id: Some(asset.id),
                template: "feature".to_string(),
                fit: "cover".to_string(),
                focal_x: 0.5,
                focal_y: 0.5,
                blur: 0.0,
                brightness: 1.0,
                regions: six_regions,
            },
        )
        .await
        .expect_err("sixth region must be rejected");
        assert!(error.to_string().contains("at most 5"));

        let detail = artist_detail(&pool, 1).await.expect("load artist detail");
        assert_eq!(detail.artist.name, "Display Artist");
        assert!(detail.artist.has_artwork);
        assert_eq!(detail.profile.genres, vec!["Pop"]);
        assert_eq!(detail.visuals[0].regions.len(), 5);

        close_test_pool(pool, path).await;
    }

    #[tokio::test]
    async fn manual_track_metadata_and_lyrics_survive_rescan() {
        let (pool, path) = test_pool().await;
        let file = FileIngest {
            library_root_id: 1,
            path: "/music/1.flac".to_string(),
            relative_path: "1.flac".to_string(),
            extension: "flac".to_string(),
            size_bytes: 1024,
            modified_at: Utc::now().to_rfc3339(),
            quick_hash: None,
            scan_status: "ok".to_string(),
            scan_message: None,
            codec: Some("flac".to_string()),
            sample_rate: Some(48_000),
            channels: Some(2),
            duration_ms: Some(180_000),
            bitrate: None,
            bit_depth: Some(24),
        };
        let mut scanned = TrackIngest {
            title: "File title".to_string(),
            album: Some("File album".to_string()),
            track_artists: vec!["File artist".to_string()],
            genres: vec!["Pop".to_string()],
            lyrics: Some("[00:01.00]file lyric".to_string()),
            lyrics_kind: Some("lrc".to_string()),
            ..Default::default()
        };
        upsert_scanned_file(&pool, &file, Some(&scanned))
            .await
            .expect("initial scan");

        let initial = track_edit_snapshot(&pool, 1)
            .await
            .expect("initial edit snapshot");
        let update = TrackMetadataUpdate {
            expected_revision: Some(initial.revision),
            fields: vec![
                protocol::TrackMetadataFieldUpdate {
                    key: "title".to_string(),
                    value: Value::String("Manual title".to_string()),
                },
                protocol::TrackMetadataFieldUpdate {
                    key: "genres".to_string(),
                    value: serde_json::json!(["Art Pop", "Live"]),
                },
            ],
            lyrics: Some(protocol::TrackLyricsUpdate {
                kind: "lrc".to_string(),
                text: "[00:02.00]manual lyric".to_string(),
                language: Some("en".to_string()),
                translation: Some("[00:02.00]人工翻译".to_string()),
                pronunciation: None,
                offset_ms: 25,
            }),
            ..Default::default()
        };
        let edited = update_track_metadata(
            &pool,
            1,
            &update,
            Some(&[protocol::LyricCue {
                start_ms: 2_025,
                text: "manual lyric".to_string(),
                ..Default::default()
            }]),
        )
        .await
        .expect("edit metadata");
        assert_eq!(edited.detail.track.title, "Manual title");
        assert_eq!(edited.detail.genres, vec!["Art Pop", "Live"]);

        scanned.title = "New file title".to_string();
        scanned.genres = vec!["Rock".to_string()];
        scanned.lyrics = Some("[00:03.00]new file lyric".to_string());
        upsert_scanned_file(&pool, &file, Some(&scanned))
            .await
            .expect("rescan");

        let after_rescan = track_edit_snapshot(&pool, 1)
            .await
            .expect("snapshot after rescan");
        assert_eq!(after_rescan.detail.track.title, "Manual title");
        assert_eq!(after_rescan.detail.genres, vec!["Art Pop", "Live"]);
        assert_eq!(
            after_rescan.detail.lyrics.as_ref().unwrap().text,
            "[00:02.00]manual lyric"
        );
        let title = after_rescan
            .fields
            .iter()
            .find(|field| field.key == "title")
            .unwrap();
        assert_eq!(
            title.file_value,
            Value::String("New file title".to_string())
        );
        assert_eq!(title.source, "manual");

        let reverted = update_track_metadata(
            &pool,
            1,
            &TrackMetadataUpdate {
                expected_revision: Some(after_rescan.revision),
                clear_fields: vec!["title".to_string()],
                ..Default::default()
            },
            None,
        )
        .await
        .expect("revert title");
        assert_eq!(reverted.detail.track.title, "New file title");

        let restored_lyrics = update_track_metadata(
            &pool,
            1,
            &TrackMetadataUpdate {
                expected_revision: Some(reverted.revision),
                clear_lyrics_override: true,
                ..Default::default()
            },
            None,
        )
        .await
        .expect("restore file lyrics");
        assert_eq!(
            restored_lyrics.detail.lyrics.as_ref().unwrap().text,
            "[00:03.00]new file lyric"
        );
        assert_eq!(
            restored_lyrics.detail.lyrics.as_ref().unwrap().source,
            "file"
        );

        close_test_pool(pool, path).await;
    }

    #[tokio::test]
    async fn client_manifests_aggregate_exact_copies_and_reconcile_missing_files() {
        let (pool, path) = test_pool().await;
        let make_manifest =
            |device_id: &str, root_id: &str, scan_id: &str, complete: bool, include_file: bool| {
                ClientLibraryManifestRequest {
                    device_id: device_id.to_string(),
                    device_name: format!("{device_id} player"),
                    platform: Some("test".to_string()),
                    root: protocol::ClientLibraryRootManifest {
                        external_id: root_id.to_string(),
                        display_name: format!("{device_id} music"),
                        path_hint: Some(format!("/{device_id}/music")),
                    },
                    scan_id: scan_id.to_string(),
                    complete,
                    files: if include_file {
                        vec![protocol::ClientLibraryFileManifest {
                            external_id: "album/01-song.flac".to_string(),
                            relative_path: "album/01-song.flac".to_string(),
                            extension: "flac".to_string(),
                            size_bytes: 4_096,
                            modified_at: Utc::now(),
                            quick_hash: Some("same-sampled-content".to_string()),
                            content_hash: None,
                            codec: Some("flac".to_string()),
                            sample_rate: Some(96_000),
                            channels: Some(2),
                            duration_ms: Some(180_000),
                            bitrate: Some(2_400_000),
                            bit_depth: Some(24),
                            metadata: ClientTrackManifest {
                                title: "Song".to_string(),
                                album: Some("Album".to_string()),
                                track_artists: vec!["Artist".to_string()],
                                album_artists: vec!["Artist".to_string()],
                                track_number: Some(1),
                                duration_ms: Some(180_000),
                                ..Default::default()
                            },
                        }]
                    } else {
                        Vec::new()
                    },
                }
            };

        let first = upsert_client_library_manifest(
            &pool,
            &make_manifest("dev-a", "root-a", "a1", true, true),
        )
        .await
        .expect("upload first client manifest");
        assert_eq!(first.accepted_files, 1);
        assert_eq!(first.missing_files, 0);
        assert_eq!(first.bindings.len(), 1);

        let tracks_after_first = list_tracks(&pool, 100, 0).await.expect("list tracks");
        assert_eq!(tracks_after_first.len(), 4);
        let client_track_id = tracks_after_first
            .iter()
            .find(|track| track.title == "Song")
            .expect("client track")
            .id;
        assert_eq!(first.bindings[0].track_id, client_track_id);

        upsert_client_library_manifest(&pool, &make_manifest("dev-b", "root-b", "b0", true, false))
            .await
            .expect("register empty destination client root");
        let relayed_distribution = create_distribution_job(
            &pool,
            &protocol::CreateDistributionRequest {
                target_device_id: "dev-b".to_string(),
                target_root_external_id: "root-b".to_string(),
                quality: "original".to_string(),
                track_ids: vec![client_track_id],
                ..Default::default()
            },
        )
        .await
        .expect("create Client-sourced distribution");
        assert_eq!(relayed_distribution.state, "awaiting_source");
        assert!(claim_distribution_source_task(&pool, "dev-b")
            .await
            .expect("query wrong source client")
            .is_none());
        let source_task = claim_distribution_source_task(&pool, "dev-a")
            .await
            .expect("claim source upload")
            .expect("Client source task");
        assert_eq!(source_task.track_id, client_track_id);
        assert_eq!(source_task.source_root_external_id, "root-a");
        assert_eq!(source_task.source_relative_path, "album/01-song.flac");
        assert_eq!(source_task.expected_size_bytes, 4_096);
        let relayed = complete_distribution_source_task(
            &pool,
            &source_task.id,
            "dev-a",
            Path::new("/cache/client-source.flac"),
            4_096,
            "same-sampled-content",
        )
        .await
        .expect("complete Client source upload");
        assert_eq!(relayed.state, "queued");
        let relayed_delivery = claim_distribution_task(&pool, "dev-b")
            .await
            .expect("claim relayed delivery")
            .expect("relayed destination task");
        let relayed_source = distribution_content_source(&pool, &relayed_delivery.id, "dev-b")
            .await
            .expect("relayed content source");
        assert_eq!(relayed_source.path, "/cache/client-source.flac");
        update_distribution_task(
            &pool,
            &relayed_delivery.id,
            &protocol::DistributionTaskProgress {
                device_id: "dev-b".to_string(),
                state: "completed".to_string(),
                transferred_bytes: 4_096,
                retryable: false,
                error: None,
            },
        )
        .await
        .expect("complete relayed delivery");

        upsert_scanned_file(
            &pool,
            &FileIngest {
                library_root_id: 1,
                path: "/music/1.flac".to_string(),
                relative_path: "1.flac".to_string(),
                extension: "flac".to_string(),
                size_bytes: 1024,
                modified_at: Utc::now().to_rfc3339(),
                quick_hash: Some("core-track-1".to_string()),
                scan_status: "ready".to_string(),
                scan_message: None,
                codec: Some("flac".to_string()),
                sample_rate: Some(48_000),
                channels: Some(2),
                duration_ms: Some(180_000),
                bitrate: Some(1_000_000),
                bit_depth: Some(24),
            },
            Some(&TrackIngest {
                title: "Track 1".to_string(),
                ..Default::default()
            }),
        )
        .await
        .expect("normalize Core source track");
        let distribution = create_distribution_job(
            &pool,
            &protocol::CreateDistributionRequest {
                target_device_id: "dev-a".to_string(),
                target_root_external_id: "root-a".to_string(),
                quality: "original".to_string(),
                track_ids: vec![1],
                ..Default::default()
            },
        )
        .await
        .expect("create distribution");
        assert_eq!(distribution.total_items, 1);
        assert_eq!(distribution.state, "queued");
        let task = claim_distribution_task(&pool, "dev-a")
            .await
            .expect("claim distribution")
            .expect("pending distribution task");
        assert_eq!(task.track_id, 1);
        assert!(task.relative_path.ends_with(".flac"));
        let source = distribution_content_source(&pool, &task.id, "dev-a")
            .await
            .expect("distribution source");
        assert_eq!(source.extension, "flac");
        let completed = update_distribution_task(
            &pool,
            &task.id,
            &protocol::DistributionTaskProgress {
                device_id: "dev-a".to_string(),
                state: "completed".to_string(),
                transferred_bytes: task.expected_size_bytes,
                retryable: false,
                error: None,
            },
        )
        .await
        .expect("complete distribution");
        assert_eq!(completed.state, "completed");
        assert_eq!(completed.completed_items, 1);
        assert!(claim_distribution_task(&pool, "dev-a")
            .await
            .expect("claim after completion")
            .is_none());
        let transcoded_distribution = create_distribution_job(
            &pool,
            &protocol::CreateDistributionRequest {
                target_device_id: "dev-a".to_string(),
                target_root_external_id: "root-a".to_string(),
                quality: "aac-256".to_string(),
                track_ids: vec![1],
                ..Default::default()
            },
        )
        .await
        .expect("create transcoded distribution");
        assert_eq!(transcoded_distribution.state, "preparing");
        assert_eq!(transcoded_distribution.total_bytes, 0);
        let transcode_task = claim_distribution_transcode_task(&pool)
            .await
            .expect("claim transcode")
            .expect("pending transcode");
        assert_eq!(transcode_task.quality, "aac-256");
        let prepared = complete_distribution_transcode_task(
            &pool,
            &transcode_task.id,
            Path::new("/cache/transcoded.m4a"),
            "m4a",
            512,
            "transcoded-hash",
        )
        .await
        .expect("complete transcode");
        assert_eq!(prepared.state, "queued");
        assert_eq!(prepared.total_bytes, 512);
        let delivery = claim_distribution_task(&pool, "dev-a")
            .await
            .expect("claim transcoded delivery")
            .expect("transcoded delivery");
        assert_eq!(delivery.extension, "m4a");
        assert_eq!(delivery.expected_size_bytes, 512);
        assert_eq!(
            delivery.expected_quick_hash.as_deref(),
            Some("transcoded-hash")
        );
        let failed_distribution = create_distribution_job(
            &pool,
            &protocol::CreateDistributionRequest {
                target_device_id: "dev-a".to_string(),
                target_root_external_id: "root-a".to_string(),
                quality: "aac-96".to_string(),
                track_ids: vec![1],
                ..Default::default()
            },
        )
        .await
        .expect("create failing transcode distribution");
        let failed_task = claim_distribution_transcode_task(&pool)
            .await
            .expect("claim failing transcode")
            .expect("failing transcode task");
        let failed = fail_distribution_transcode_task(
            &pool,
            &failed_task.id,
            false,
            "test transcode failure",
        )
        .await
        .expect("record terminal transcode failure");
        assert_eq!(failed.id, failed_distribution.id);
        assert_eq!(failed.state, "completed_with_errors");
        assert_eq!(failed.failed_items, 1);
        assert_eq!(failed.error.as_deref(), Some("test transcode failure"));
        assert!(create_distribution_job(
            &pool,
            &protocol::CreateDistributionRequest {
                target_device_id: "dev-a".to_string(),
                target_root_external_id: "root-a".to_string(),
                quality: "arbitrary-shell-arguments".to_string(),
                track_ids: vec![1],
                ..Default::default()
            },
        )
        .await
        .expect_err("unknown transcoding profile must fail")
        .to_string()
        .contains("unknown distribution quality profile"));

        let mutation_request = protocol::ClientMutationBatchRequest {
            device_id: "dev-a".to_string(),
            device_name: "Device A".to_string(),
            platform: Some("test".to_string()),
            mutations: vec![
                protocol::ClientMutation {
                    id: "favorite-1".to_string(),
                    kind: "favorite".to_string(),
                    track_id: client_track_id,
                    occurred_at: Utc::now(),
                    payload: serde_json::json!({"is_favorite": true}),
                },
                protocol::ClientMutation {
                    id: "playback-1".to_string(),
                    kind: "playback".to_string(),
                    track_id: client_track_id,
                    occurred_at: Utc::now(),
                    payload: serde_json::json!({
                        "started_at": Utc::now().to_rfc3339(),
                        "ended_at": Utc::now().to_rfc3339(),
                        "start_position_ms": 0,
                        "end_position_ms": 120_000,
                        "reason": "completed"
                    }),
                },
            ],
        };
        let applied = apply_client_mutations(&pool, &mutation_request)
            .await
            .expect("apply offline mutations");
        assert_eq!(applied.applied_ids.len(), 2);
        let duplicate = apply_client_mutations(&pool, &mutation_request)
            .await
            .expect("reapply offline mutations");
        assert_eq!(duplicate.duplicate_ids.len(), 2);
        assert!(
            track_detail(&pool, client_track_id)
                .await
                .expect("favorite detail")
                .track
                .is_favorite
        );
        assert_eq!(
            list_playback_sessions(&pool, 20, 0, None, None)
                .await
                .expect("offline playback sessions")
                .into_iter()
                .filter(|session| session.track_id == client_track_id)
                .count(),
            1,
            "idempotent replay must create exactly one playback session"
        );

        upsert_client_library_manifest(&pool, &make_manifest("dev-b", "root-b", "b1", true, true))
            .await
            .expect("upload exact copy from second client");
        let tracks_after_second = list_tracks(&pool, 100, 0).await.expect("list tracks");
        assert_eq!(
            tracks_after_second.len(),
            4,
            "an exact copy must add a replica, not a duplicate catalog track"
        );
        let media = track_media_profile(&pool, client_track_id)
            .await
            .expect("load media")
            .expect("media profile");
        assert_eq!(media.variants.len(), 1);
        assert_eq!(media.variants[0].replicas.len(), 2);
        assert!(media.variants[0]
            .replicas
            .iter()
            .any(|replica| replica.device_id.as_deref() == Some("dev-a")
                && replica.root_external_id.as_deref() == Some("root-a")));
        assert!(media.variants[0]
            .replicas
            .iter()
            .any(|replica| replica.device_id.as_deref() == Some("dev-b")
                && replica.root_external_id.as_deref() == Some("root-b")));

        let reconciled = upsert_client_library_manifest(
            &pool,
            &make_manifest("dev-a", "root-a", "a2", true, false),
        )
        .await
        .expect("reconcile removed file");
        assert_eq!(reconciled.missing_files, 1);
        let media = track_media_profile(&pool, client_track_id)
            .await
            .expect("load reconciled media")
            .expect("media profile");
        assert!(media.variants[0].replicas.iter().any(|replica| {
            replica.device_id.as_deref() == Some("dev-a") && replica.availability_state == "missing"
        }));
        assert!(media.variants[0].replicas.iter().any(|replica| {
            replica.device_id.as_deref() == Some("dev-b") && replica.availability_state == "ready"
        }));

        remove_client_library_root(&pool, "dev-b", "root-b")
            .await
            .expect("remove second client root");
        let statuses = list_client_library_roots(&pool)
            .await
            .expect("list client roots");
        assert_eq!(statuses.len(), 2);
        assert_eq!(
            list_library_roots(&pool)
                .await
                .expect("list core roots")
                .len(),
            1,
            "client-owned roots must not leak into Core scan settings"
        );

        close_test_pool(pool, path).await;
    }
}
