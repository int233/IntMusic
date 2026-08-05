use super::*;

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
        WHERE scan_status IN ('needs_attention', 'tag_parse_error')
          AND deleted_at IS NULL
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
