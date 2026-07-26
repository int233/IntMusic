use super::*;

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
