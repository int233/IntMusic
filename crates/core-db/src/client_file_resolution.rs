use super::*;

pub(crate) fn normalize_client_metadata_status(status: &str) -> String {
    match status.trim() {
        "tag_parse_error" => "tag_parse_error",
        "needs_attention" => "needs_attention",
        _ => "needs_attention",
    }
    .to_string()
}

pub async fn list_client_library_pending_files(
    pool: &DbPool,
) -> Result<Vec<ClientLibraryPendingFile>> {
    let rows = sqlx::query(
        r#"
        SELECT
            file.id AS file_id,
            COALESCE(root.owner_device_id, 'core') AS device_id,
            COALESCE(device.name, 'Core local') AS device_name,
            COALESCE(root.external_id, CAST(root.id AS TEXT)) AS root_external_id,
            COALESCE(
                NULLIF(root.display_name, ''),
                root.external_id,
                root.path
            ) AS root_display_name,
            COALESCE(file.client_file_id, file.relative_path) AS client_file_id,
            file.relative_path,
            file.extension,
            file.size_bytes,
            file.modified_at,
            file.scan_status,
            file.scan_message,
            file.codec,
            file.sample_rate,
            file.channels,
            file.duration_ms,
            file.bitrate,
            file.bit_depth,
            source.data_json AS metadata_json
        FROM files file
        JOIN library_roots root ON root.id = file.library_root_id
        LEFT JOIN devices device ON device.id = root.owner_device_id
        LEFT JOIN track_metadata_sources source ON source.file_id = file.id
        WHERE file.deleted_at IS NULL
          AND (
              file.scan_status IN ('needs_attention', 'tag_parse_error', 'ignored')
              OR EXISTS (
                  SELECT 1
                  FROM library_file_issues issue
                  WHERE issue.file_id = file.id AND issue.state = 'open'
              )
          )
        ORDER BY
            CASE file.scan_status
                WHEN 'tag_parse_error' THEN 0
                WHEN 'needs_attention' THEN 1
                WHEN 'ignored' THEN 2
                ELSE 3
            END,
            device.name COLLATE NOCASE,
            file.relative_path COLLATE NOCASE
        LIMIT 2000
        "#,
    )
    .fetch_all(pool)
    .await?;
    rows.into_iter()
        .map(|row| {
            Ok(ClientLibraryPendingFile {
                file_id: row.try_get("file_id")?,
                device_id: row.try_get("device_id")?,
                device_name: row.try_get("device_name")?,
                root_external_id: row.try_get("root_external_id")?,
                root_display_name: row.try_get("root_display_name")?,
                client_file_id: row.try_get("client_file_id")?,
                relative_path: row.try_get("relative_path")?,
                extension: row.try_get("extension")?,
                size_bytes: row.try_get("size_bytes")?,
                modified_at: row.try_get("modified_at")?,
                scan_status: row.try_get("scan_status")?,
                scan_message: row.try_get("scan_message")?,
                codec: row.try_get("codec")?,
                sample_rate: row.try_get("sample_rate")?,
                channels: row.try_get("channels")?,
                duration_ms: row.try_get("duration_ms")?,
                bitrate: row.try_get("bitrate")?,
                bit_depth: row.try_get("bit_depth")?,
                metadata: row
                    .try_get::<Option<String>, _>("metadata_json")?
                    .map(|value| serde_json::from_str(&value))
                    .transpose()
                    .context("invalid pending-file metadata")?,
            })
        })
        .collect()
}

pub async fn resolve_client_library_file(
    pool: &DbPool,
    file_id: i64,
    action: &str,
    target_track_id: Option<i64>,
    manual_metadata: Option<&ClientTrackManifest>,
) -> Result<ResolveClientLibraryFileResult> {
    let action = action.trim();
    let _root_kind: String = sqlx::query_scalar(
        r#"
        SELECT root.root_kind
        FROM files file
        JOIN library_roots root ON root.id = file.library_root_id
        WHERE file.id = ?1 AND file.deleted_at IS NULL
        "#,
    )
    .bind(file_id)
    .fetch_one(pool)
    .await
    .context("client library file was not found")?;
    let now = Utc::now().to_rfc3339();
    match action {
        "match" => {
            let target_track_id = target_track_id.context("target_track_id is required")?;
            let exists: Option<i64> = sqlx::query_scalar("SELECT id FROM tracks WHERE id = ?1")
                .bind(target_track_id)
                .fetch_optional(pool)
                .await?;
            if exists.is_none() {
                bail!("target track does not exist");
            }
            sqlx::query(
                r#"
                INSERT INTO client_file_resolutions (
                    file_id, resolution_kind, target_track_id, metadata_json,
                    created_at, updated_at
                )
                VALUES (?1, 'matched_track', ?2, NULL, ?3, ?3)
                ON CONFLICT(file_id) DO UPDATE SET
                    resolution_kind = excluded.resolution_kind,
                    target_track_id = excluded.target_track_id,
                    metadata_json = NULL,
                    updated_at = excluded.updated_at
                "#,
            )
            .bind(file_id)
            .bind(target_track_id)
            .bind(&now)
            .execute(pool)
            .await?;
            attach_client_file_to_track(pool, file_id, target_track_id).await?;
            sqlx::query("DELETE FROM tracks WHERE file_id = ?1 AND id <> ?2")
                .bind(file_id)
                .bind(target_track_id)
                .execute(pool)
                .await?;
            refresh_file_management_issues(pool, file_id).await?;
            resolution_result(pool, file_id, action, Some(target_track_id)).await
        }
        "metadata" => {
            let metadata = manual_metadata.context("metadata is required")?;
            if metadata.title.trim().is_empty() || metadata.track_artists.is_empty() {
                bail!("manual metadata requires a title and at least one artist");
            }
            let file = file_ingest_by_id(pool, file_id).await?;
            let track = client_track_manifest_to_ingest(metadata, &file.relative_path);
            upsert_scanned_file(pool, &file, Some(&track)).await?;
            let track_id = track_id_for_file(pool, file_id)
                .await?
                .context("manual metadata did not create a track")?;
            let metadata_json = serde_json::to_string(metadata)?;
            sqlx::query(
                r#"
                INSERT INTO client_file_resolutions (
                    file_id, resolution_kind, target_track_id, metadata_json,
                    created_at, updated_at
                )
                VALUES (?1, 'manual_metadata', ?2, ?3, ?4, ?4)
                ON CONFLICT(file_id) DO UPDATE SET
                    resolution_kind = excluded.resolution_kind,
                    target_track_id = excluded.target_track_id,
                    metadata_json = excluded.metadata_json,
                    updated_at = excluded.updated_at
                "#,
            )
            .bind(file_id)
            .bind(track_id)
            .bind(metadata_json)
            .bind(&now)
            .execute(pool)
            .await?;
            sqlx::query(
                r#"
                UPDATE files
                SET scan_status = 'ok', scan_message = NULL, updated_at = ?1
                WHERE id = ?2
                "#,
            )
            .bind(&now)
            .bind(file_id)
            .execute(pool)
            .await?;
            mark_client_replica_ready(pool, file_id, &now).await?;
            refresh_file_management_issues(pool, file_id).await?;
            resolution_result(pool, file_id, action, Some(track_id)).await
        }
        "ignore" => {
            sqlx::query(
                r#"
                INSERT INTO client_file_resolutions (
                    file_id, resolution_kind, target_track_id, metadata_json,
                    created_at, updated_at
                )
                VALUES (?1, 'ignored', NULL, NULL, ?2, ?2)
                ON CONFLICT(file_id) DO UPDATE SET
                    resolution_kind = excluded.resolution_kind,
                    target_track_id = NULL,
                    metadata_json = NULL,
                    updated_at = excluded.updated_at
                "#,
            )
            .bind(file_id)
            .bind(&now)
            .execute(pool)
            .await?;
            sqlx::query("DELETE FROM tracks WHERE file_id = ?1")
                .bind(file_id)
                .execute(pool)
                .await?;
            sqlx::query(
                "UPDATE files SET scan_status = 'ignored', scan_message = NULL, updated_at = ?1 WHERE id = ?2",
            )
            .bind(&now)
            .bind(file_id)
            .execute(pool)
            .await?;
            sqlx::query(
                "UPDATE media_replicas SET availability_state = 'ignored', updated_at = ?1 WHERE file_id = ?2",
            )
            .bind(&now)
            .bind(file_id)
            .execute(pool)
            .await?;
            refresh_file_management_issues(pool, file_id).await?;
            Ok(ResolveClientLibraryFileResult {
                file_id,
                action: action.to_string(),
                track_id: None,
                media_variant_id: None,
                scan_status: "ignored".to_string(),
            })
        }
        "reset" => {
            sqlx::query("DELETE FROM client_file_resolutions WHERE file_id = ?1")
                .bind(file_id)
                .execute(pool)
                .await?;
            sqlx::query(
                "UPDATE files SET scan_status = 'needs_attention', scan_message = 'Waiting for this device to rescan embedded tags', updated_at = ?1 WHERE id = ?2",
            )
            .bind(&now)
            .bind(file_id)
            .execute(pool)
            .await?;
            refresh_file_management_issues(pool, file_id).await?;
            Ok(ResolveClientLibraryFileResult {
                file_id,
                action: action.to_string(),
                track_id: None,
                media_variant_id: None,
                scan_status: "needs_attention".to_string(),
            })
        }
        _ => bail!("unsupported client-file resolution action"),
    }
}

async fn resolution_result(
    pool: &DbPool,
    file_id: i64,
    action: &str,
    preferred_track_id: Option<i64>,
) -> Result<ResolveClientLibraryFileResult> {
    let scan_status: String = sqlx::query_scalar("SELECT scan_status FROM files WHERE id = ?1")
        .bind(file_id)
        .fetch_one(pool)
        .await?;
    let row = sqlx::query(
        r#"
        SELECT replica.media_variant_id, MIN(links.track_id) AS track_id
        FROM media_replicas replica
        LEFT JOIN release_track_media_variants relation
          ON relation.media_variant_id = replica.media_variant_id
        LEFT JOIN legacy_track_catalog_links links
          ON links.release_track_id = relation.release_track_id
        WHERE replica.file_id = ?1
        GROUP BY replica.media_variant_id
        "#,
    )
    .bind(file_id)
    .fetch_optional(pool)
    .await?;
    Ok(ResolveClientLibraryFileResult {
        file_id,
        action: action.to_string(),
        track_id: preferred_track_id.or_else(|| {
            row.as_ref()
                .and_then(|value| value.try_get::<Option<i64>, _>("track_id").ok())
                .flatten()
        }),
        media_variant_id: row
            .as_ref()
            .and_then(|value| value.try_get("media_variant_id").ok()),
        scan_status,
    })
}

pub(crate) async fn mark_client_replica_ready(
    pool: &DbPool,
    file_id: i64,
    now: &str,
) -> Result<()> {
    sqlx::query(
        r#"
        UPDATE media_replicas
        SET device_id = (
                SELECT root.owner_device_id
                FROM files file
                JOIN library_roots root ON root.id = file.library_root_id
                WHERE file.id = ?1
            ),
            library_root_id = (
                SELECT library_root_id FROM files WHERE id = ?1
            ),
            source_kind = (
                SELECT CASE root.root_kind
                    WHEN 'client' THEN 'client'
                    ELSE 'core'
                END
                FROM files file
                JOIN library_roots root ON root.id = file.library_root_id
                WHERE file.id = ?1
            ),
            availability_state = 'ready',
            last_verified_at = ?2,
            updated_at = ?2
        WHERE file_id = ?1
        "#,
    )
    .bind(file_id)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(())
}

pub(crate) async fn attach_client_file_to_track(
    pool: &DbPool,
    file_id: i64,
    target_track_id: i64,
) -> Result<i64> {
    let now = Utc::now().to_rfc3339();
    let target = sqlx::query(
        r#"
        SELECT
            links.release_track_id,
            variant.audio_master_id
        FROM legacy_track_catalog_links links
        JOIN release_track_media_variants relation
          ON relation.release_track_id = links.release_track_id
        JOIN media_variants variant ON variant.id = relation.media_variant_id
        WHERE links.track_id = ?1
        ORDER BY relation.is_preferred DESC, variant.id
        LIMIT 1
        "#,
    )
    .bind(target_track_id)
    .fetch_one(pool)
    .await
    .context("target track has no media identity")?;
    let release_track_id: i64 = target.try_get("release_track_id")?;
    let audio_master_id: i64 = target.try_get("audio_master_id")?;
    let file = file_ingest_by_id(pool, file_id).await?;
    let content_hash: Option<String> =
        sqlx::query_scalar("SELECT content_hash FROM files WHERE id = ?1")
            .bind(file_id)
            .fetch_optional(pool)
            .await?
            .flatten();
    let exact_variant_id: Option<i64> = sqlx::query_scalar(
        r#"
        SELECT variant.id
        FROM legacy_track_catalog_links links
        JOIN release_track_media_variants relation
          ON relation.release_track_id = links.release_track_id
        JOIN media_variants variant ON variant.id = relation.media_variant_id
        JOIN media_replicas replica ON replica.media_variant_id = variant.id
        JOIN files existing_file ON existing_file.id = replica.file_id
        WHERE links.track_id = ?1
          AND existing_file.id <> ?2
          AND existing_file.size_bytes = ?3
          AND (
              (?4 IS NOT NULL AND ?4 <> '' AND variant.content_hash = ?4)
              OR
              (?5 IS NOT NULL AND ?5 <> '' AND variant.quick_hash = ?5)
          )
        ORDER BY relation.is_preferred DESC, variant.id
        LIMIT 1
        "#,
    )
    .bind(target_track_id)
    .bind(file_id)
    .bind(file.size_bytes)
    .bind(&content_hash)
    .bind(&file.quick_hash)
    .fetch_optional(pool)
    .await?;
    let media_variant_id = if let Some(variant_id) = exact_variant_id {
        variant_id
    } else if let Some(variant_id) =
        sqlx::query_scalar("SELECT media_variant_id FROM media_replicas WHERE file_id = ?1")
            .bind(file_id)
            .fetch_optional(pool)
            .await?
    {
        sqlx::query(
            r#"
            UPDATE media_variants
            SET audio_master_id = ?1, codec = ?2, container = ?3,
                bitrate = ?4, sample_rate = ?5, bit_depth = ?6,
                channels = ?7, duration_ms = ?8, content_hash = ?9,
                quick_hash = ?10, updated_at = ?11
            WHERE id = ?12
            "#,
        )
        .bind(audio_master_id)
        .bind(&file.codec)
        .bind(&file.extension)
        .bind(file.bitrate)
        .bind(file.sample_rate)
        .bind(file.bit_depth)
        .bind(file.channels)
        .bind(file.duration_ms)
        .bind(&content_hash)
        .bind(&file.quick_hash)
        .bind(&now)
        .bind(variant_id)
        .execute(pool)
        .await?;
        sqlx::query("DELETE FROM release_track_media_variants WHERE media_variant_id = ?1")
            .bind(variant_id)
            .execute(pool)
            .await?;
        variant_id
    } else {
        sqlx::query_scalar(
            r#"
            INSERT INTO media_variants (
                global_id, audio_master_id, variant_key, codec, container,
                bitrate, sample_rate, bit_depth, channels, duration_ms,
                content_hash, quick_hash, created_at, updated_at
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?13)
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
        .bind(file.duration_ms)
        .bind(&content_hash)
        .bind(&file.quick_hash)
        .bind(&now)
        .fetch_one(pool)
        .await?
    };
    sqlx::query(
        r#"
        INSERT INTO release_track_media_variants (
            release_track_id, media_variant_id, relation_kind, is_preferred, created_at
        )
        VALUES (?1, ?2, 'manual_match', 0, ?3)
        ON CONFLICT(release_track_id, media_variant_id) DO NOTHING
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
            media_variant_id, file_id, device_id, library_root_id,
            source_kind, availability_state, is_primary,
            last_verified_at, created_at, updated_at
        )
        SELECT
            ?1, file.id, root.owner_device_id, file.library_root_id,
            CASE root.root_kind WHEN 'client' THEN 'client' ELSE 'core' END,
            'ready', 0, ?2, ?2, ?2
        FROM files file
        JOIN library_roots root ON root.id = file.library_root_id
        WHERE file.id = ?3
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
    .bind(&now)
    .bind(file_id)
    .execute(pool)
    .await?;
    sqlx::query(
        "UPDATE files SET scan_status = 'identified', scan_message = NULL, updated_at = ?1 WHERE id = ?2",
    )
    .bind(&now)
    .bind(file_id)
    .execute(pool)
    .await?;
    Ok(media_variant_id)
}
