use super::*;

pub(crate) async fn upsert_track(
    pool: &DbPool,
    file_id: i64,
    _library_root_id: i64,
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
        let album_key = album_key(&album_artists, album_title, track.year);
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

pub(crate) async fn ensure_track_media_graph(
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
    let master_label = (mastering_kind != "unknown")
        .then_some(track.subtitle.as_deref())
        .flatten()
        .map(str::trim)
        .filter(|value| !value.is_empty());

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
        ON CONFLICT(file_id) DO UPDATE SET
            media_variant_id = excluded.media_variant_id,
            library_root_id = excluded.library_root_id,
            availability_state = 'ready',
            last_verified_at = excluded.last_verified_at,
            updated_at = excluded.updated_at
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

pub(crate) async fn ensure_release_edition_for_track(
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

pub(crate) async fn update_media_variant(
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

pub(crate) async fn file_ingest_by_id(pool: &DbPool, file_id: i64) -> Result<FileIngest> {
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

pub(crate) fn inferred_recording_kind(subtitle: Option<&str>) -> &'static str {
    let subtitle = subtitle.unwrap_or_default().to_ascii_lowercase();
    if subtitle.contains("cover") || subtitle.contains("翻唱") {
        "cover"
    } else if subtitle.contains("remix") || subtitle.contains("混音") {
        "remix"
    } else if subtitle.contains("radio edit")
        || subtitle.contains("single edit")
        || subtitle.contains("剪辑版")
    {
        "edit"
    } else if subtitle.contains("live") || subtitle.contains("现场") {
        "live"
    } else if subtitle.contains("acoustic") || subtitle.contains("不插电") {
        "acoustic"
    } else if subtitle.contains("demo") {
        "demo"
    } else if subtitle.contains("instrumental")
        || subtitle.contains("伴奏")
        || subtitle.contains("纯音乐")
    {
        "instrumental"
    } else if subtitle.contains("karaoke") {
        "karaoke"
    } else {
        "unknown"
    }
}

pub(crate) fn inferred_mastering_kind(subtitle: Option<&str>) -> &'static str {
    let subtitle = subtitle.unwrap_or_default().to_ascii_lowercase();
    if subtitle.contains("remaster") || subtitle.contains("重制") {
        "remaster"
    } else {
        "unknown"
    }
}

pub(crate) async fn upsert_artist(pool: &DbPool, name: &str) -> Result<i64> {
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

pub(crate) async fn insert_track_artist_role(
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

pub(crate) async fn upsert_genre(pool: &DbPool, name: &str) -> Result<i64> {
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

pub(crate) async fn rebuild_track_search_row(pool: &DbPool, track_id: i64) -> Result<()> {
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
