use super::*;

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
