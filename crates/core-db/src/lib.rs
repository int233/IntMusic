use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    str::FromStr,
};

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use protocol::{
    AlbumDetail, AlbumSummary, ArtistDetail, ArtistSummary, LibraryCounts, LibraryRoot,
    LyricPayload, NewPlaylist, PlaybackEvent, PlaybackSession, PlaybackStats, PlaylistDetail,
    PlaylistKind, PlaylistSummary, PlaylistTrackMutation, ScanProblem, TrackDetail,
    TrackFavoriteUpdate, TrackPlaybackStat, TrackSummary, UpdatePlaylist,
};
use serde_json::Value;
use sqlx::{
    sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous},
    QueryBuilder, Row, Sqlite, SqlitePool,
};

pub type DbPool = SqlitePool;

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
    sqlx::migrate!("./src/migrations")
        .run(pool)
        .await
        .context("failed to run database migrations")?;
    Ok(())
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

#[derive(Debug, Clone, Default)]
pub struct TrackIngest {
    pub title: String,
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
        upsert_track(pool, file_id, file.library_root_id, track).await?;
    } else {
        sqlx::query("DELETE FROM tracks WHERE file_id = ?1")
            .bind(file_id)
            .execute(pool)
            .await?;
    }

    Ok(file_id)
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
            file_id, album_id, title, disc_number, disc_total, track_number, track_total,
            duration_ms, date, year, comment, tag_rating, tag_rating_scale, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?14)
        ON CONFLICT(file_id) DO UPDATE SET
            album_id = excluded.album_id,
            title = excluded.title,
            disc_number = excluded.disc_number,
            disc_total = excluded.disc_total,
            track_number = excluded.track_number,
            track_total = excluded.track_total,
            duration_ms = excluded.duration_ms,
            date = excluded.date,
            year = excluded.year,
            comment = excluded.comment,
            tag_rating = excluded.tag_rating,
            tag_rating_scale = excluded.tag_rating_scale,
            updated_at = excluded.updated_at
        "#,
    )
    .bind(file_id)
    .bind(album_id)
    .bind(&track.title)
    .bind(track.disc_number)
    .bind(track.disc_total)
    .bind(track.track_number)
    .bind(track.track_total)
    .bind(track.duration_ms)
    .bind(&track.date)
    .bind(track.year)
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
            INSERT INTO lyrics (track_id, kind, text, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?4)
            ON CONFLICT(track_id) DO UPDATE SET
                kind = excluded.kind,
                text = excluded.text,
                parsed_json = NULL,
                updated_at = excluded.updated_at
            "#,
        )
        .bind(track_id)
        .bind(lyrics_kind)
        .bind(lyrics)
        .bind(&now)
        .execute(pool)
        .await?;
    } else {
        sqlx::query("DELETE FROM lyrics WHERE track_id = ?1")
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
        SELECT ar.id, ar.name, ar.sort_name,
               COUNT(DISTINCT ta.track_id) AS track_count,
               COUNT(DISTINCT aa.album_id) AS album_count
        FROM artists ar
        LEFT JOIN track_artists ta ON ta.artist_id = ar.id
        LEFT JOIN album_artists aa ON aa.artist_id = ar.id
        GROUP BY ar.id
        ORDER BY COALESCE(ar.sort_name, ar.name) COLLATE NOCASE
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
        SELECT ar.id, ar.name, ar.sort_name,
               COUNT(DISTINCT ta.track_id) AS track_count,
               COUNT(DISTINCT aa.album_id) AS album_count
        FROM artists ar
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

pub async fn list_tracks(pool: &DbPool, limit: u32, offset: u32) -> Result<Vec<TrackSummary>> {
    let rows =
        sqlx::query(track_select_sql("GROUP BY t.id ORDER BY t.id LIMIT ?1 OFFSET ?2").as_str())
            .bind(limit as i64)
            .bind(offset as i64)
            .fetch_all(pool)
            .await?;

    rows.into_iter().map(row_to_track).collect()
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

    let lyrics = sqlx::query("SELECT kind, text FROM lyrics WHERE track_id = ?1")
        .bind(track_id)
        .fetch_optional(pool)
        .await?
        .map(|row| {
            Ok::<_, sqlx::Error>(LyricPayload {
                kind: row.try_get("kind")?,
                text: row.try_get("text")?,
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
        SELECT ar.id, ar.name, ar.sort_name,
               COUNT(DISTINCT ta.track_id) AS track_count,
               COUNT(DISTINCT aa.album_id) AS album_count
        FROM artists ar
        LEFT JOIN track_artists ta ON ta.artist_id = ar.id
        LEFT JOIN album_artists aa ON aa.artist_id = ar.id
        WHERE ar.name LIKE ?1
        GROUP BY ar.id
        ORDER BY ar.name COLLATE NOCASE
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
    format!(
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
