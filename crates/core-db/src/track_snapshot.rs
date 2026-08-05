use super::*;

pub async fn track_stream_source(pool: &DbPool, track_id: i64) -> Result<(String, String)> {
    let normalized = sqlx::query(
        r#"
        SELECT file.path, file.extension
        FROM tracks target
        JOIN legacy_track_catalog_links link ON link.track_id = target.id
        JOIN release_track_media_variants relation
          ON relation.release_track_id = link.release_track_id
        JOIN media_replicas replica
          ON replica.media_variant_id = relation.media_variant_id
        JOIN files file ON file.id = replica.file_id
        WHERE target.id = ?1
          AND replica.source_kind = 'core'
          AND replica.availability_state = 'ready'
          AND file.deleted_at IS NULL
        ORDER BY
          CASE WHEN file.id = target.file_id THEN 0 ELSE 1 END,
          relation.is_preferred DESC,
          replica.is_primary DESC,
          file.id
        LIMIT 1
        "#,
    )
    .bind(track_id)
    .fetch_optional(pool)
    .await?;
    if let Some(row) = normalized {
        return Ok((row.try_get("path")?, row.try_get("extension")?));
    }
    let fallback = sqlx::query(
        r#"
        SELECT file.path, file.extension
        FROM tracks track
        JOIN files file ON file.id = track.file_id
        WHERE track.id = ?1
        "#,
    )
    .bind(track_id)
    .fetch_one(pool)
    .await?;
    Ok((fallback.try_get("path")?, fallback.try_get("extension")?))
}

pub(crate) async fn current_track_ingest(pool: &DbPool, track_id: i64) -> Result<TrackIngest> {
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
