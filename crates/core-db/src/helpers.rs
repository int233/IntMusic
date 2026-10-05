use super::*;

pub(crate) async fn track_artist_role_names(
    pool: &DbPool,
    track_id: i64,
    role: &str,
) -> Result<Vec<String>> {
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

pub(crate) fn row_to_library_root(row: sqlx::sqlite::SqliteRow) -> Result<LibraryRoot> {
    Ok(LibraryRoot {
        id: row.try_get("id")?,
        path: row.try_get("path")?,
        enabled: row.try_get::<i64, _>("enabled")? != 0,
        created_at: parse_datetime(row.try_get::<String, _>("created_at")?)?,
        updated_at: parse_datetime(row.try_get::<String, _>("updated_at")?)?,
    })
}

pub(crate) fn row_to_album(row: sqlx::sqlite::SqliteRow) -> Result<AlbumSummary> {
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

pub(crate) fn row_to_artist(row: sqlx::sqlite::SqliteRow) -> Result<ArtistSummary> {
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

pub(crate) fn row_to_track(row: sqlx::sqlite::SqliteRow) -> Result<TrackSummary> {
    let artists: Vec<String> = serde_json::from_str(&row.try_get::<String, _>("display_artists")?)?;
    let mut artists = artists
        .iter()
        .map(|a| normalize_text(a))
        .filter(|a| !a.is_empty())
        .collect::<Vec<_>>();
    artists.sort();
    artists.dedup();
    let title = normalize_text(&row.try_get::<String, _>("title")?);
    let display_group_key = if title.is_empty() || artists.is_empty() {
        None
    } else {
        Some(serde_json::to_string(&(title, artists))?)
    };
    Ok(TrackSummary {
        display_group_key,
        is_available: row.try_get("is_available")?,
        display_mode: row.try_get("display_mode")?,
        release_identity_id: row.try_get("release_identity_id")?,
        genres: serde_json::from_str(&row.try_get::<String, _>("genres")?)?,
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

pub(crate) fn push_track_select_builder(query: &mut QueryBuilder<'_, Sqlite>) {
    query.push(
        r#"
        SELECT
            t.id, t.file_id,
            COALESCE(display_link.release_identity_id, display_link.release_track_id) AS release_identity_id,
            display_mode.mode AS display_mode,
            EXISTS(SELECT 1 FROM tracks playable
              CROSS JOIN files pf ON pf.id = playable.file_id
              CROSS JOIN library_roots pr ON pr.id = pf.library_root_id
              LEFT JOIN devices pd ON pd.id = pr.owner_device_id
              WHERE playable.id IN (SELECT t.id UNION ALL SELECT copy.track_id FROM track_catalog_links copy
                WHERE COALESCE(copy.release_identity_id, copy.release_track_id) = COALESCE(display_link.release_identity_id, display_link.release_track_id))
                AND pf.deleted_at IS NULL AND pf.scan_status IN ('ok', 'identified', 'ready') AND pr.retired_at IS NULL
                AND (pr.owner_device_id IS NULL OR datetime(pd.online_until) >= datetime('now'))) AS is_available,
            (SELECT json_group_array(a.name) FROM track_artists ta JOIN artists a ON a.id = ta.artist_id
             WHERE ta.track_id = t.id AND ta.role = 'primary') AS display_artists,
            (SELECT json_group_array(g.name) FROM track_genres tg JOIN genres g ON g.id = tg.genre_id
             WHERE tg.track_id = t.id) AS genres,
            COALESCE(summary_album_identity.canonical_album_id, t.album_id) AS album_id,
            t.title,
            COALESCE(GROUP_CONCAT(DISTINCT ar.name), NULL) AS artist_display,
            COALESCE(NULLIF(summary_album_profile.title, ''), al.title) AS album_title,
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
                   OR ps.track_id IN (
                        SELECT member.track_id
                        FROM track_merge_members member
                        WHERE member.canonical_track_id = t.id
                   )
            ) AS play_count
        "#,
    );
    push_track_from_joins(query);
}

pub(crate) fn push_track_from_joins(query: &mut QueryBuilder<'_, Sqlite>) {
    query.push(
        r#"
        FROM tracks t
        LEFT JOIN track_catalog_links display_link ON display_link.track_id = t.id
        JOIN track_display_modes display_mode ON display_mode.track_id = t.id
        LEFT JOIN album_identity_members summary_album_identity
          ON summary_album_identity.album_id = t.album_id
        LEFT JOIN albums al
          ON al.id = COALESCE(summary_album_identity.canonical_album_id, t.album_id)
        LEFT JOIN album_metadata_profiles summary_album_profile
          ON summary_album_profile.album_id = al.id
        LEFT JOIN track_artists ta ON ta.track_id = t.id AND ta.role = 'primary'
        LEFT JOIN artists ar ON ar.id = ta.artist_id
        LEFT JOIN user_track_state uts ON uts.track_id = t.id
        LEFT JOIN files f ON f.id = t.file_id
        "#,
    );
}

pub(crate) fn row_to_playback_event(row: sqlx::sqlite::SqliteRow) -> Result<PlaybackEvent> {
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

pub(crate) fn row_to_playback_session(row: sqlx::sqlite::SqliteRow) -> Result<PlaybackSession> {
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

pub(crate) fn row_to_track_playback_stat(
    row: sqlx::sqlite::SqliteRow,
) -> Result<TrackPlaybackStat> {
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

pub(crate) async fn get_playback_event(pool: &DbPool, id: i64) -> Result<PlaybackEvent> {
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

pub(crate) async fn get_playback_session(pool: &DbPool, id: i64) -> Result<PlaybackSession> {
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

pub(crate) async fn open_playback_session_id(pool: &DbPool, zone_id: &str) -> Result<Option<i64>> {
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

pub(crate) fn track_select_sql(tail: &str) -> String {
    track_select_sql_extra("", tail)
}

pub(crate) fn track_select_sql_extra(extra_select: &str, tail: &str) -> String {
    let mut query = QueryBuilder::<Sqlite>::new("");
    push_track_select_builder(&mut query);
    query
        .sql()
        .replacen("SELECT", &format!("SELECT {extra_select}"), 1)
        + tail
}

pub(crate) fn parse_datetime(value: String) -> Result<DateTime<Utc>> {
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

pub(crate) fn album_key(album_artists: &[String], album_title: &str, year: Option<i64>) -> String {
    let mut artists = album_artists
        .iter()
        .map(|artist| normalize_text(artist))
        .filter(|artist| !artist.is_empty())
        .collect::<Vec<_>>();
    artists.sort();
    artists.dedup();
    format!(
        "catalog:{}\u{1f}{}\u{1f}{}",
        normalize_text(album_title),
        artists.join("\u{1e}"),
        year.map(|year| year.to_string()).unwrap_or_default(),
    )
}
