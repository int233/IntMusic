use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    str::FromStr,
};

use anyhow::{bail, Context, Result};
use chrono::{DateTime, Utc};
use protocol::{
    AlbumDetail, AlbumSummary, ArtistAsset, ArtistDetail, ArtistProfile, ArtistSummary,
    ArtistVisual, ArtistVisualRegion, LibraryCounts, LibraryRoot, LyricPayload, NewPlaylist,
    PlaybackEvent, PlaybackMode, PlaybackQueue, PlaybackQueueItem, PlaybackSession, PlaybackStats,
    PlaylistDetail, PlaylistKind, PlaylistSummary, PlaylistTrackMutation, ReplacePlaybackQueue,
    ScanProblem, TrackDetail, TrackEditSnapshot, TrackFavoriteUpdate, TrackMetadataField,
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
        .foreign_keys(true);

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
        INSERT INTO library_roots (path, enabled, created_at, updated_at)
        VALUES (?1, 1, ?2, ?2)
        ON CONFLICT(path) DO UPDATE SET enabled = 1, updated_at = excluded.updated_at
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
        "SELECT id, path, enabled, created_at, updated_at FROM library_roots ORDER BY path",
    )
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_library_root).collect()
}

pub async fn enabled_library_roots(pool: &DbPool) -> Result<Vec<LibraryRoot>> {
    let rows = sqlx::query(
        "SELECT id, path, enabled, created_at, updated_at FROM library_roots WHERE enabled = 1 ORDER BY path",
    )
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_library_root).collect()
}

async fn get_library_root_by_path(pool: &DbPool, path: &str) -> Result<LibraryRoot> {
    let row = sqlx::query(
        "SELECT id, path, enabled, created_at, updated_at FROM library_roots WHERE path = ?1",
    )
    .bind(path)
    .fetch_one(pool)
    .await?;
    row_to_library_root(row)
}

pub async fn library_counts(pool: &DbPool) -> Result<LibraryCounts> {
    Ok(LibraryCounts {
        library_roots: count(pool, "library_roots", "enabled = 1").await?,
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
        upsert_track(pool, file_id, file.library_root_id, &effective).await?;
    } else {
        sqlx::query("DELETE FROM tracks WHERE file_id = ?1")
            .bind(file_id)
            .execute(pool)
            .await?;
    }

    Ok(file_id)
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
    upsert_track(pool, file_id, library_root_id, &effective).await?;

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
}
