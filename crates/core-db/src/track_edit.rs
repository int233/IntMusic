use super::*;

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
    Ok(track_stream_source(pool, track_id).await?.0)
}

pub async fn search_tracks(pool: &DbPool, query: &str, limit: u32) -> Result<Vec<TrackSummary>> {
    let pattern = format!("%{}%", query);
    let rows = sqlx::query(
        track_select_sql(
            r#"
            WHERE (
                  t.title LIKE ?1
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
              )
              AND NOT EXISTS (
                    SELECT 1 FROM track_merge_members member
                    WHERE member.track_id = t.id
              )
              AND (
                    NOT EXISTS (
                      SELECT 1 FROM legacy_track_catalog_links missing_link
                      WHERE missing_link.track_id = t.id
                    )
                    OR t.id = (
                    SELECT MIN(candidate.track_id)
                    FROM legacy_track_catalog_links candidate
                    JOIN release_tracks candidate_release
                      ON candidate_release.id = candidate.release_track_id
                    LEFT JOIN track_merge_members member
                      ON member.track_id = candidate.track_id
                    WHERE member.track_id IS NULL
                      AND candidate_release.recording_id = (
                        SELECT current_release.recording_id
                        FROM legacy_track_catalog_links current_link
                        JOIN release_tracks current_release
                          ON current_release.id = current_link.release_track_id
                        WHERE current_link.track_id = t.id
                      )
                    )
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
               al.cover_asset_id,
               COUNT(DISTINCT CASE WHEN member.track_id IS NULL THEN COALESCE(
                   'release:' || links.release_track_id,
                   'legacy:' || t.id
               ) END) AS track_count
        FROM albums al
        LEFT JOIN tracks t ON t.album_id = al.id
        LEFT JOIN legacy_track_catalog_links links ON links.track_id = t.id
        LEFT JOIN track_merge_members member ON member.track_id = t.id
        WHERE al.title LIKE ?1 OR al.album_artist_display LIKE ?1
        GROUP BY al.id
        HAVING track_count > 0
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
