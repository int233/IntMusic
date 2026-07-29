use super::*;

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

    let resolution = sqlx::query(
        r#"
        SELECT resolution_kind, target_track_id, metadata_json
        FROM client_file_resolutions
        WHERE file_id = ?1
        "#,
    )
    .bind(file_id)
    .fetch_optional(pool)
    .await?;
    let resolution_kind = resolution
        .as_ref()
        .and_then(|row| row.try_get::<String, _>("resolution_kind").ok());
    let manual_manifest = resolution
        .as_ref()
        .and_then(|row| row.try_get::<Option<String>, _>("metadata_json").ok())
        .flatten()
        .map(|value| serde_json::from_str::<ClientTrackManifest>(&value))
        .transpose()
        .context("invalid saved file metadata")?;
    let manual_track = manual_manifest
        .as_ref()
        .map(|metadata| client_track_manifest_to_ingest(metadata, &file.relative_path));
    let effective_track = match resolution_kind.as_deref() {
        Some("manual_metadata") => manual_track.as_ref(),
        Some("matched_track") | Some("ignored") => None,
        _ => track,
    };

    if let Some(track) = effective_track {
        save_track_metadata_source(pool, file_id, track).await?;
        let mut effective = track.clone();
        if let Some(track_id) = track_id_for_file(pool, file_id).await? {
            apply_metadata_overrides(
                &mut effective,
                &load_track_metadata_overrides(pool, track_id).await?,
            )?;
        }
        let track_id = upsert_track(pool, file_id, file.library_root_id, &effective).await?;
        ensure_track_media_graph(pool, track_id, file_id, file, &effective).await?;
    } else {
        sqlx::query("DELETE FROM tracks WHERE file_id = ?1")
            .bind(file_id)
            .execute(pool)
            .await?;
    }

    match resolution_kind.as_deref() {
        Some("manual_metadata") => {
            sqlx::query(
                "UPDATE files SET scan_status = 'ok', scan_message = NULL, updated_at = ?1 WHERE id = ?2",
            )
            .bind(&now)
            .bind(file_id)
            .execute(pool)
            .await?;
            mark_client_replica_ready(pool, file_id, &now).await?;
        }
        Some("matched_track") => {
            let target_track_id = resolution
                .as_ref()
                .and_then(|row| row.try_get::<Option<i64>, _>("target_track_id").ok())
                .flatten()
                .context("matched file resolution is missing its target track")?;
            attach_client_file_to_track(pool, file_id, target_track_id).await?;
        }
        Some("ignored") => {
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
        }
        _ => {}
    }

    refresh_file_management_issues(pool, file_id).await?;
    Ok(file_id)
}

pub async fn upsert_client_library_manifest(
    pool: &DbPool,
    manifest: &ClientLibraryManifestRequest,
) -> Result<ClientLibraryManifestResult> {
    let device_id = manifest.device_id.trim();
    let device_name = manifest.device_name.trim();
    let root_external_id = manifest.root.external_id.trim();
    let root_display_name = manifest.root.display_name.trim();
    let scan_id = manifest.scan_id.trim();
    if device_id.is_empty() || device_id.len() > 200 {
        bail!("device_id must contain between 1 and 200 characters");
    }
    if device_name.is_empty() || device_name.len() > 300 {
        bail!("device_name must contain between 1 and 300 characters");
    }
    if root_external_id.is_empty() || root_external_id.len() > 200 {
        bail!("root.external_id must contain between 1 and 200 characters");
    }
    if root_display_name.is_empty() || root_display_name.len() > 500 {
        bail!("root.display_name must contain between 1 and 500 characters");
    }
    if scan_id.is_empty() || scan_id.len() > 200 {
        bail!("scan_id must contain between 1 and 200 characters");
    }
    if manifest.files.len() > 1_000 {
        bail!("a client library manifest batch cannot exceed 1000 files");
    }

    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT INTO devices (
            id, name, platform, token_hash, created_at, last_seen_at
        )
        VALUES (?1, ?2, ?3, 'client-library-manifest', ?4, ?4)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            platform = COALESCE(excluded.platform, devices.platform),
            last_seen_at = excluded.last_seen_at,
            retired_at = NULL,
            removed_at = NULL
        "#,
    )
    .bind(device_id)
    .bind(device_name)
    .bind(&manifest.platform)
    .bind(&now)
    .execute(pool)
    .await?;

    let root_path = format!(
        "intmusic-client://{}/{}",
        stable_shadow_segment(device_id),
        stable_shadow_segment(root_external_id)
    );
    sqlx::query(
        r#"
        INSERT INTO library_roots (
            path, enabled, root_kind, owner_device_id, external_id,
            display_name, path_hint, last_seen_at, created_at, updated_at
        )
        VALUES (?1, 1, 'client', ?2, ?3, ?4, ?5, ?6, ?6, ?6)
        ON CONFLICT(root_kind, owner_device_id, external_id)
        DO UPDATE SET
            enabled = 1,
            display_name = excluded.display_name,
            path_hint = excluded.path_hint,
            last_seen_at = excluded.last_seen_at,
            retired_at = NULL,
            updated_at = excluded.updated_at
        "#,
    )
    .bind(&root_path)
    .bind(device_id)
    .bind(root_external_id)
    .bind(root_display_name)
    .bind(manifest.root.path_hint.as_deref().map(str::trim))
    .bind(&now)
    .execute(pool)
    .await?;
    let root_id: i64 = sqlx::query_scalar(
        r#"
        SELECT id
        FROM library_roots
        WHERE root_kind = 'client' AND owner_device_id = ?1 AND external_id = ?2
        "#,
    )
    .bind(device_id)
    .bind(root_external_id)
    .fetch_one(pool)
    .await?;

    sqlx::query(
        r#"
        INSERT INTO client_library_sync_state (
            device_id, root_external_id, scan_id, started_at,
            completed_at, accepted_files, missing_files
        )
        VALUES (?1, ?2, ?3, ?4, NULL, 0, 0)
        ON CONFLICT(device_id, root_external_id) DO UPDATE SET
            scan_id = excluded.scan_id,
            started_at = CASE
                WHEN client_library_sync_state.scan_id = excluded.scan_id
                THEN client_library_sync_state.started_at
                ELSE excluded.started_at
            END,
            completed_at = CASE
                WHEN client_library_sync_state.scan_id = excluded.scan_id
                THEN client_library_sync_state.completed_at
                ELSE NULL
            END,
            accepted_files = CASE
                WHEN client_library_sync_state.scan_id = excluded.scan_id
                THEN client_library_sync_state.accepted_files
                ELSE 0
            END,
            missing_files = CASE
                WHEN client_library_sync_state.scan_id = excluded.scan_id
                THEN client_library_sync_state.missing_files
                ELSE 0
            END
        "#,
    )
    .bind(device_id)
    .bind(root_external_id)
    .bind(scan_id)
    .bind(&now)
    .execute(pool)
    .await?;

    let mut accepted_files = 0_i64;
    let mut bindings = Vec::with_capacity(manifest.files.len());
    for item in &manifest.files {
        let client_file_id = item.external_id.trim();
        let relative_path = item.relative_path.trim().replace('\\', "/");
        if client_file_id.is_empty() || client_file_id.len() > 1_000 {
            bail!("file external_id must contain between 1 and 1000 characters");
        }
        if relative_path.is_empty() || relative_path.len() > 4_096 {
            bail!("file relative_path must contain between 1 and 4096 characters");
        }
        let extension = item
            .extension
            .trim()
            .trim_start_matches('.')
            .to_ascii_lowercase();
        if extension.is_empty() || extension.len() > 32 {
            bail!("file extension must contain between 1 and 32 characters");
        }
        if item.size_bytes < 0 {
            bail!("file size_bytes cannot be negative");
        }
        let shadow_path = format!(
            "{}/{}",
            root_path.trim_end_matches('/'),
            stable_shadow_segment(client_file_id)
        );
        let existing_file_id: Option<i64> =
            sqlx::query_scalar("SELECT id FROM files WHERE path = ?1")
                .bind(&shadow_path)
                .fetch_optional(pool)
                .await?;
        let existing_resolution = if let Some(file_id) = existing_file_id {
            sqlx::query(
                r#"
                SELECT resolution_kind, target_track_id, metadata_json
                FROM client_file_resolutions
                WHERE file_id = ?1
                "#,
            )
            .bind(file_id)
            .fetch_optional(pool)
            .await?
        } else {
            None
        };
        let resolution_kind = existing_resolution
            .as_ref()
            .and_then(|row| row.try_get::<String, _>("resolution_kind").ok());
        let resolved_track_id = existing_resolution
            .as_ref()
            .and_then(|row| row.try_get::<Option<i64>, _>("target_track_id").ok())
            .flatten();
        let manual_metadata = existing_resolution
            .as_ref()
            .and_then(|row| row.try_get::<Option<String>, _>("metadata_json").ok())
            .flatten()
            .map(|value| serde_json::from_str::<ClientTrackManifest>(&value))
            .transpose()
            .context("invalid manual client-file metadata")?;
        let embedded_metadata_ready = item.metadata_status.trim() == "ready"
            && !item.metadata.title.trim().is_empty()
            && !item.metadata.track_artists.is_empty();
        let matching_variant_id: Option<i64> = if resolution_kind.is_none() {
            if let Some(content_hash) = item
                .content_hash
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                sqlx::query_scalar(
                    r#"
                    SELECT variant.id
                    FROM media_variants variant
                    JOIN media_replicas replica ON replica.media_variant_id = variant.id
                    JOIN files existing_file ON existing_file.id = replica.file_id
                    JOIN release_track_media_variants relation
                      ON relation.media_variant_id = variant.id
                    JOIN legacy_track_catalog_links links
                      ON links.release_track_id = relation.release_track_id
                    WHERE variant.content_hash = ?1
                      AND existing_file.size_bytes = ?2
                      AND existing_file.id <> COALESCE(?3, -1)
                      AND existing_file.deleted_at IS NULL
                    ORDER BY replica.is_primary DESC, variant.id
                    LIMIT 1
                    "#,
                )
                .bind(content_hash)
                .bind(item.size_bytes)
                .bind(existing_file_id)
                .fetch_optional(pool)
                .await?
            } else if let Some(quick_hash) = item
                .quick_hash
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                sqlx::query_scalar(
                    r#"
                    SELECT variant.id
                    FROM media_variants variant
                    JOIN media_replicas replica ON replica.media_variant_id = variant.id
                    JOIN files existing_file ON existing_file.id = replica.file_id
                    JOIN release_track_media_variants relation
                      ON relation.media_variant_id = variant.id
                    JOIN legacy_track_catalog_links links
                      ON links.release_track_id = relation.release_track_id
                    WHERE variant.quick_hash = ?1
                      AND existing_file.size_bytes = ?2
                      AND existing_file.id <> COALESCE(?3, -1)
                      AND existing_file.deleted_at IS NULL
                    ORDER BY replica.is_primary DESC, variant.id
                    LIMIT 1
                    "#,
                )
                .bind(quick_hash)
                .bind(item.size_bytes)
                .bind(existing_file_id)
                .fetch_optional(pool)
                .await?
            } else {
                None
            }
        } else {
            None
        };
        let effective_manifest = manual_metadata.as_ref().unwrap_or(&item.metadata);
        let metadata = client_track_manifest_to_ingest(effective_manifest, &relative_path);
        let manually_ignored = resolution_kind.as_deref() == Some("ignored");
        let manually_matched = resolution_kind.as_deref() == Some("matched_track");
        let manually_edited = resolution_kind.as_deref() == Some("manual_metadata");
        let creates_catalog_track = manually_edited
            || (!manually_ignored
                && !manually_matched
                && embedded_metadata_ready
                && matching_variant_id.is_none());
        let scan_status = if manually_ignored {
            "ignored".to_string()
        } else if manually_matched || matching_variant_id.is_some() {
            "identified".to_string()
        } else if creates_catalog_track {
            "ok".to_string()
        } else {
            normalize_client_metadata_status(&item.metadata_status)
        };
        let file = FileIngest {
            library_root_id: root_id,
            path: shadow_path,
            relative_path,
            extension,
            size_bytes: item.size_bytes,
            modified_at: item.modified_at.to_rfc3339(),
            quick_hash: item.quick_hash.clone(),
            scan_status,
            scan_message: item.metadata_message.clone(),
            codec: item.codec.clone(),
            sample_rate: item.sample_rate,
            channels: item.channels,
            duration_ms: item.duration_ms,
            bitrate: item.bitrate,
            bit_depth: item.bit_depth,
        };
        let file_id =
            upsert_scanned_file(pool, &file, creates_catalog_track.then_some(&metadata)).await?;
        if resolution_kind.is_none()
            && (!metadata.title.trim().is_empty()
                || !metadata.track_artists.is_empty()
                || metadata.album.is_some())
        {
            save_track_metadata_source(pool, file_id, &metadata).await?;
        }
        sqlx::query(
            r#"
            UPDATE files
            SET client_file_id = ?1,
                content_hash = ?2,
                last_seen_scan_id = ?3,
                availability_state = 'ready',
                deleted_at = NULL,
                updated_at = ?4
            WHERE id = ?5
            "#,
        )
        .bind(client_file_id)
        .bind(&item.content_hash)
        .bind(scan_id)
        .bind(&now)
        .bind(file_id)
        .execute(pool)
        .await?;
        if manually_ignored {
            sqlx::query(
                "UPDATE media_replicas SET availability_state = 'ignored', updated_at = ?1 WHERE file_id = ?2",
            )
            .bind(&now)
            .bind(file_id)
            .execute(pool)
            .await?;
            accepted_files += 1;
            continue;
        }
        sqlx::query(
            r#"
            UPDATE media_variants
            SET content_hash = ?1, updated_at = ?2
            WHERE id = (
                SELECT media_variant_id
                FROM media_replicas
                WHERE file_id = ?3
            )
            "#,
        )
        .bind(&item.content_hash)
        .bind(&now)
        .bind(file_id)
        .execute(pool)
        .await?;
        if manually_matched {
            let target_track_id = resolved_track_id
                .context("matched client-file resolution is missing its target track")?;
            attach_client_file_to_track(pool, file_id, target_track_id).await?;
        } else if let Some(media_variant_id) = matching_variant_id {
            sqlx::query(
                r#"
                INSERT INTO media_replicas (
                    media_variant_id, file_id, device_id, library_root_id,
                    source_kind, availability_state, is_primary,
                    last_verified_at, created_at, updated_at
                )
                VALUES (?1, ?2, ?3, ?4, 'client', 'ready', 0, ?5, ?5, ?5)
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
            .bind(file_id)
            .bind(device_id)
            .bind(root_id)
            .bind(&now)
            .execute(pool)
            .await?;
        } else {
            sqlx::query(
                r#"
                UPDATE media_replicas
                SET device_id = ?1,
                    library_root_id = ?2,
                    source_kind = 'client',
                    availability_state = 'ready',
                    last_verified_at = ?3,
                    updated_at = ?3
                WHERE file_id = ?4
                "#,
            )
            .bind(device_id)
            .bind(root_id)
            .bind(&now)
            .bind(file_id)
            .execute(pool)
            .await?;
        }
        let binding_row = sqlx::query(
            r#"
            SELECT replica.media_variant_id, MIN(links.track_id) AS track_id
            FROM media_replicas replica
            JOIN release_track_media_variants relation
              ON relation.media_variant_id = replica.media_variant_id
            JOIN legacy_track_catalog_links links
              ON links.release_track_id = relation.release_track_id
            WHERE replica.file_id = ?1
            GROUP BY replica.media_variant_id
            "#,
        )
        .bind(file_id)
        .fetch_optional(pool)
        .await?;
        if let Some(binding_row) = binding_row {
            bindings.push(ClientLibraryFileBinding {
                external_id: client_file_id.to_string(),
                track_id: binding_row.try_get("track_id")?,
                media_variant_id: binding_row.try_get("media_variant_id")?,
            });
        }
        accepted_files += 1;
    }

    sqlx::query(
        r#"
        UPDATE client_library_sync_state
        SET accepted_files = accepted_files + ?1
        WHERE device_id = ?2 AND root_external_id = ?3 AND scan_id = ?4
        "#,
    )
    .bind(accepted_files)
    .bind(device_id)
    .bind(root_external_id)
    .bind(scan_id)
    .execute(pool)
    .await?;

    let mut missing_files = 0_i64;
    if manifest.complete {
        let result = sqlx::query(
            r#"
            UPDATE files
            SET availability_state = 'missing',
                deleted_at = COALESCE(deleted_at, ?1),
                updated_at = ?1
            WHERE library_root_id = ?2
              AND client_file_id IS NOT NULL
              AND COALESCE(last_seen_scan_id, '') <> ?3
              AND deleted_at IS NULL
            "#,
        )
        .bind(&now)
        .bind(root_id)
        .bind(scan_id)
        .execute(pool)
        .await?;
        missing_files = i64::try_from(result.rows_affected()).unwrap_or(i64::MAX);
        sqlx::query(
            r#"
            UPDATE media_replicas
            SET availability_state = 'missing', updated_at = ?1
            WHERE library_root_id = ?2
              AND file_id IN (
                  SELECT id FROM files
                  WHERE library_root_id = ?2
                    AND COALESCE(last_seen_scan_id, '') <> ?3
              )
            "#,
        )
        .bind(&now)
        .bind(root_id)
        .bind(scan_id)
        .execute(pool)
        .await?;
        sqlx::query(
            r#"
            UPDATE client_library_sync_state
            SET completed_at = ?1, missing_files = ?2
            WHERE device_id = ?3 AND root_external_id = ?4 AND scan_id = ?5
            "#,
        )
        .bind(&now)
        .bind(missing_files)
        .bind(device_id)
        .bind(root_external_id)
        .bind(scan_id)
        .execute(pool)
        .await?;
    }

    Ok(ClientLibraryManifestResult {
        root_id,
        accepted_files,
        missing_files,
        complete: manifest.complete,
        bindings,
    })
}

pub async fn remove_client_library_root(
    pool: &DbPool,
    device_id: &str,
    root_external_id: &str,
) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    let root_id: Option<i64> = sqlx::query_scalar(
        r#"
        SELECT id
        FROM library_roots
        WHERE root_kind = 'client' AND owner_device_id = ?1 AND external_id = ?2
        "#,
    )
    .bind(device_id)
    .bind(root_external_id)
    .fetch_optional(pool)
    .await?;
    let Some(root_id) = root_id else {
        return Ok(());
    };
    sqlx::query(
        "UPDATE library_roots SET enabled = 0, retired_at = COALESCE(retired_at, ?1), updated_at = ?1 WHERE id = ?2",
    )
        .bind(&now)
        .bind(root_id)
        .execute(pool)
        .await?;
    sqlx::query(
        r#"
        UPDATE files
        SET availability_state = 'missing',
            deleted_at = COALESCE(deleted_at, ?1),
            updated_at = ?1
        WHERE library_root_id = ?2
        "#,
    )
    .bind(&now)
    .bind(root_id)
    .execute(pool)
    .await?;
    sqlx::query(
        r#"
        UPDATE media_replicas
        SET availability_state = 'missing', updated_at = ?1
        WHERE library_root_id = ?2
        "#,
    )
    .bind(&now)
    .bind(root_id)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn list_client_library_roots(pool: &DbPool) -> Result<Vec<ClientLibraryRootStatus>> {
    let rows = sqlx::query(
        r#"
        SELECT
            root.id AS root_id,
            root.external_id,
            COALESCE(NULLIF(root.display_name, ''), root.external_id) AS display_name,
            root.owner_device_id AS device_id,
            device.name AS device_name,
            device.platform,
            root.path_hint,
            root.enabled,
            COUNT(file.id) AS file_count,
            COALESCE(SUM(CASE
                WHEN file.deleted_at IS NULL
                 AND file.availability_state = 'ready'
                 AND file.scan_status IN ('ok', 'identified')
                THEN 1 ELSE 0 END), 0) AS ready_file_count,
            sync.scan_id AS last_scan_id,
            root.last_seen_at,
            sync.completed_at
        FROM library_roots root
        JOIN devices device ON device.id = root.owner_device_id
        LEFT JOIN files file ON file.library_root_id = root.id
        LEFT JOIN client_library_sync_state sync
          ON sync.device_id = root.owner_device_id
         AND sync.root_external_id = root.external_id
        WHERE root.root_kind = 'client'
        GROUP BY root.id
        ORDER BY device.name COLLATE NOCASE, display_name COLLATE NOCASE
        "#,
    )
    .fetch_all(pool)
    .await?;
    rows.into_iter()
        .map(|row| {
            let last_seen_at: Option<String> = row.try_get("last_seen_at")?;
            let completed_at: Option<String> = row.try_get("completed_at")?;
            Ok(ClientLibraryRootStatus {
                root_id: row.try_get("root_id")?,
                external_id: row.try_get("external_id")?,
                display_name: row.try_get("display_name")?,
                device_id: row.try_get("device_id")?,
                device_name: row.try_get("device_name")?,
                platform: row.try_get("platform")?,
                path_hint: row.try_get("path_hint")?,
                enabled: row.try_get::<i64, _>("enabled")? != 0,
                file_count: row.try_get("file_count")?,
                ready_file_count: row.try_get("ready_file_count")?,
                last_scan_id: row.try_get("last_scan_id")?,
                last_seen_at: last_seen_at.map(parse_datetime).transpose()?,
                completed_at: completed_at.map(parse_datetime).transpose()?,
            })
        })
        .collect()
}
