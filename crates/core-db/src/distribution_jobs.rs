use super::*;

pub async fn create_distribution_job(
    pool: &DbPool,
    request: &CreateDistributionRequest,
) -> Result<DistributionJobSummary> {
    let target_device_id = request.target_device_id.trim();
    let target_root_external_id = request.target_root_external_id.trim();
    if target_device_id.is_empty() || target_device_id.len() > 200 {
        bail!("target_device_id must contain between 1 and 200 characters");
    }
    if target_root_external_id.is_empty() || target_root_external_id.len() > 300 {
        bail!("target_root_external_id must contain between 1 and 300 characters");
    }
    let quality = request.quality.trim().to_ascii_lowercase();
    let profile_extension = distribution_profile_extension(&quality)?;

    let mut tx = pool.begin().await?;
    let target_exists: Option<i64> = sqlx::query_scalar(
        r#"
        SELECT root.id
        FROM library_roots root
        WHERE root.root_kind = 'client'
          AND root.owner_device_id = ?1
          AND root.external_id = ?2
          AND root.enabled = 1
        "#,
    )
    .bind(target_device_id)
    .bind(target_root_external_id)
    .fetch_optional(&mut *tx)
    .await?;
    if target_exists.is_none() {
        bail!("the target Client library folder is not registered or is disabled");
    }

    let mut track_ids = request
        .track_ids
        .iter()
        .copied()
        .filter(|id| *id > 0)
        .collect::<Vec<_>>();
    for album_id in request.album_ids.iter().copied().filter(|id| *id > 0) {
        track_ids.extend(
            sqlx::query_scalar::<_, i64>(
                r#"
                SELECT id
                FROM tracks
                WHERE album_id = ?1
                ORDER BY COALESCE(disc_number, 1), COALESCE(track_number, 0), id
                "#,
            )
            .bind(album_id)
            .fetch_all(&mut *tx)
            .await?,
        );
    }
    for playlist_id in request.playlist_ids.iter().copied().filter(|id| *id > 0) {
        track_ids.extend(
            sqlx::query_scalar::<_, i64>(
                r#"
                SELECT track_id
                FROM playlist_items
                WHERE playlist_id = ?1
                ORDER BY position, id
                "#,
            )
            .bind(playlist_id)
            .fetch_all(&mut *tx)
            .await?,
        );
    }
    track_ids.sort_unstable();
    track_ids.dedup();
    if track_ids.is_empty() {
        bail!("a distribution job must contain at least one track");
    }
    if track_ids.len() > 5_000 {
        bail!("a distribution job cannot exceed 5000 tracks");
    }

    let now = Utc::now().to_rfc3339();
    let job_id = Uuid::now_v7().to_string();
    sqlx::query(
        r#"
        INSERT INTO distribution_jobs (
            id, target_device_id, target_root_external_id, quality,
            state, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, 'queued', ?5, ?5)
        "#,
    )
    .bind(&job_id)
    .bind(target_device_id)
    .bind(target_root_external_id)
    .bind(&quality)
    .bind(&now)
    .execute(&mut *tx)
    .await?;

    let mut relative_paths = HashSet::new();
    let mut total_bytes = 0_i64;
    let mut completed_items = 0_i64;
    for track_id in &track_ids {
        let source = sqlx::query(
            r#"
            SELECT
                variant.id AS media_variant_id,
                file.id AS source_file_id,
                file.path AS source_file_path,
                file.extension,
                file.size_bytes,
                file.quick_hash,
                replica.source_kind,
                replica.device_id AS source_device_id,
                root.external_id AS source_root_external_id,
                file.relative_path AS source_relative_path,
                track.title,
                track.disc_number,
                track.track_number,
                album.title AS album_title,
                album.album_artist_display,
                (
                    SELECT GROUP_CONCAT(artist.name, ', ')
                    FROM track_artists track_artist
                    JOIN artists artist ON artist.id = track_artist.artist_id
                    WHERE track_artist.track_id = track.id
                      AND track_artist.role = 'primary'
                    ORDER BY track_artist.position
                ) AS artist_display
            FROM tracks track
            JOIN legacy_track_catalog_links link ON link.track_id = track.id
            JOIN release_track_media_variants relation
              ON relation.release_track_id = link.release_track_id
            JOIN media_variants variant ON variant.id = relation.media_variant_id
            JOIN media_replicas replica ON replica.media_variant_id = variant.id
            JOIN files file ON file.id = replica.file_id
            JOIN library_roots root ON root.id = replica.library_root_id
            LEFT JOIN albums album ON album.id = track.album_id
            WHERE track.id = ?1
              AND replica.availability_state = 'ready'
              AND file.deleted_at IS NULL
              AND file.availability_state = 'ready'
            ORDER BY
                CASE WHEN replica.source_kind = 'core' THEN 0 ELSE 1 END,
                root.last_seen_at DESC,
                relation.is_preferred DESC,
                replica.is_primary DESC,
                COALESCE(variant.bit_depth, 0) DESC,
                COALESCE(variant.bitrate, 0) DESC,
                file.id
            LIMIT 1
            "#,
        )
        .bind(track_id)
        .fetch_optional(&mut *tx)
        .await?
        .with_context(|| format!("track {track_id} has no available media replica"))?;
        let media_variant_id: i64 = source.try_get("media_variant_id")?;
        let source_file_id: i64 = source.try_get("source_file_id")?;
        let source_file_path: String = source.try_get("source_file_path")?;
        let source_kind: String = source.try_get("source_kind")?;
        let source_device_id: Option<String> = source.try_get("source_device_id")?;
        let source_root_external_id: Option<String> = source.try_get("source_root_external_id")?;
        let source_relative_path: String = source.try_get("source_relative_path")?;
        let requires_source_upload = source_kind != "core";
        if requires_source_upload
            && (source_device_id.as_deref().is_none_or(str::is_empty)
                || source_root_external_id.as_deref().is_none_or(str::is_empty))
        {
            bail!("track {track_id} has an invalid Client media replica");
        }
        let source_extension: String = source.try_get("extension")?;
        let extension = profile_extension
            .unwrap_or(source_extension.as_str())
            .to_string();
        let size_bytes: i64 = source.try_get("size_bytes")?;
        let title: String = source.try_get("title")?;
        let album_title: Option<String> = source.try_get("album_title")?;
        let album_artist: Option<String> = source.try_get("album_artist_display")?;
        let track_artist: Option<String> = source.try_get("artist_display")?;
        let disc_number: Option<i64> = source.try_get("disc_number")?;
        let track_number: Option<i64> = source.try_get("track_number")?;
        let quick_hash: Option<String> = source.try_get("quick_hash")?;
        let already_present: Option<i64> = if quality == "original" {
            sqlx::query_scalar(
                r#"
                SELECT 1
                FROM media_replicas
                WHERE media_variant_id = ?1
                  AND device_id = ?2
                  AND availability_state = 'ready'
                LIMIT 1
                "#,
            )
            .bind(media_variant_id)
            .bind(target_device_id)
            .fetch_optional(&mut *tx)
            .await?
        } else {
            None
        };
        let artist = track_artist
            .as_deref()
            .or(album_artist.as_deref())
            .unwrap_or("Unknown Artist");
        let album = album_title.as_deref().unwrap_or("Unknown Album");
        let mut relative_path = distribution_relative_path(
            artist,
            album,
            &title,
            disc_number,
            track_number,
            &extension,
        );
        if !relative_paths.insert(relative_path.clone()) {
            let path = Path::new(&relative_path);
            let stem = path
                .file_stem()
                .and_then(|value| value.to_str())
                .unwrap_or("track");
            let parent = path.parent().unwrap_or_else(|| Path::new(""));
            relative_path = parent
                .join(format!("{stem} (track {track_id}).{extension}"))
                .to_string_lossy()
                .replace('\\', "/");
            relative_paths.insert(relative_path.clone());
        }
        let item_state = if already_present.is_some() {
            completed_items += 1;
            "skipped"
        } else if requires_source_upload {
            "awaiting_source"
        } else if quality == "original" {
            total_bytes = total_bytes.saturating_add(size_bytes.max(0));
            "queued"
        } else {
            "preparing"
        };
        let expected_size = if quality == "original" {
            size_bytes.max(0)
        } else {
            0
        };
        let expected_hash = if quality == "original" {
            quick_hash
        } else {
            None
        };
        let content_file_path = if quality == "original" && !requires_source_upload {
            Some(source_file_path)
        } else {
            None
        };
        sqlx::query(
            r#"
            INSERT INTO distribution_items (
                id, job_id, track_id, media_variant_id, source_file_id,
                relative_path, extension, expected_size_bytes,
                expected_quick_hash, content_file_path, state,
                source_device_id, source_root_external_id, source_relative_path,
                created_at, updated_at, completed_at
            )
            VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11,
                ?12, ?13, ?14, ?15, ?15,
                CASE WHEN ?11 = 'skipped' THEN ?15 ELSE NULL END
            )
            "#,
        )
        .bind(Uuid::now_v7().to_string())
        .bind(&job_id)
        .bind(track_id)
        .bind(media_variant_id)
        .bind(source_file_id)
        .bind(relative_path)
        .bind(extension.to_ascii_lowercase())
        .bind(expected_size)
        .bind(expected_hash)
        .bind(content_file_path)
        .bind(item_state)
        .bind(source_device_id)
        .bind(source_root_external_id)
        .bind(source_relative_path)
        .bind(&now)
        .execute(&mut *tx)
        .await?;
    }

    sqlx::query(
        r#"
        UPDATE distribution_jobs
        SET total_items = ?1,
            completed_items = ?2,
            total_bytes = ?3,
            updated_at = ?4
        WHERE id = ?5
        "#,
    )
    .bind(track_ids.len() as i64)
    .bind(completed_items)
    .bind(total_bytes)
    .bind(&now)
    .bind(&job_id)
    .execute(&mut *tx)
    .await?;
    refresh_distribution_job_totals(&mut tx, &job_id, &now).await?;
    tx.commit().await?;
    get_distribution_job(pool, &job_id).await
}

pub async fn list_distribution_jobs(
    pool: &DbPool,
    target_device_id: Option<&str>,
    limit: u32,
) -> Result<Vec<DistributionJobSummary>> {
    let rows = sqlx::query(
        r#"
        SELECT
            job.*,
            device.name AS target_device_name,
            COALESCE(NULLIF(root.display_name, ''), root.external_id)
                AS target_root_name
        FROM distribution_jobs job
        JOIN devices device ON device.id = job.target_device_id
        JOIN library_roots root
          ON root.root_kind = 'client'
         AND root.owner_device_id = job.target_device_id
         AND root.external_id = job.target_root_external_id
        WHERE (?1 IS NULL OR job.target_device_id = ?1)
        ORDER BY job.created_at DESC
        LIMIT ?2
        "#,
    )
    .bind(target_device_id)
    .bind(limit.clamp(1, 500))
    .fetch_all(pool)
    .await?;
    rows.into_iter().map(row_to_distribution_job).collect()
}

pub async fn get_distribution_job(pool: &DbPool, job_id: &str) -> Result<DistributionJobSummary> {
    let row = sqlx::query(
        r#"
        SELECT
            job.*,
            device.name AS target_device_name,
            COALESCE(NULLIF(root.display_name, ''), root.external_id)
                AS target_root_name
        FROM distribution_jobs job
        JOIN devices device ON device.id = job.target_device_id
        JOIN library_roots root
          ON root.root_kind = 'client'
         AND root.owner_device_id = job.target_device_id
         AND root.external_id = job.target_root_external_id
        WHERE job.id = ?1
        "#,
    )
    .bind(job_id)
    .fetch_one(pool)
    .await?;
    row_to_distribution_job(row)
}

pub async fn claim_distribution_task(
    pool: &DbPool,
    device_id: &str,
) -> Result<Option<DistributionTaskAssignment>> {
    let device_id = device_id.trim();
    if device_id.is_empty() || device_id.len() > 200 {
        bail!("device_id must contain between 1 and 200 characters");
    }
    let now = Utc::now();
    let now_text = now.to_rfc3339();
    let lease_text = (now + chrono::Duration::minutes(30)).to_rfc3339();
    let mut tx = pool.begin().await?;
    sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = CASE WHEN attempt_count >= 3 THEN 'failed' ELSE 'queued' END,
            error = CASE
                WHEN attempt_count >= 3 THEN 'delivery lease expired after 3 attempts'
                ELSE error
            END,
            lease_expires_at = NULL,
            updated_at = ?1
        WHERE state = 'transferring'
          AND lease_expires_at IS NOT NULL
          AND lease_expires_at < ?1
          AND job_id IN (
              SELECT id FROM distribution_jobs WHERE target_device_id = ?2
          )
        "#,
    )
    .bind(&now_text)
    .bind(device_id)
    .execute(&mut *tx)
    .await?;

    let candidate: Option<String> = sqlx::query_scalar(
        r#"
        SELECT item.id
        FROM distribution_items item
        JOIN distribution_jobs job ON job.id = item.job_id
        WHERE job.target_device_id = ?1
          AND job.state NOT IN ('cancelled', 'completed', 'completed_with_errors')
          AND item.state = 'queued'
        ORDER BY job.created_at, item.created_at
        LIMIT 1
        "#,
    )
    .bind(device_id)
    .fetch_optional(&mut *tx)
    .await?;
    let Some(task_id) = candidate else {
        tx.commit().await?;
        return Ok(None);
    };
    let claimed = sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = 'transferring',
            attempt_count = attempt_count + 1,
            claimed_at = ?1,
            lease_expires_at = ?2,
            error = NULL,
            updated_at = ?1
        WHERE id = ?3 AND state = 'queued'
        "#,
    )
    .bind(&now_text)
    .bind(&lease_text)
    .bind(&task_id)
    .execute(&mut *tx)
    .await?;
    if claimed.rows_affected() == 0 {
        tx.commit().await?;
        return Ok(None);
    }
    sqlx::query(
        r#"
        UPDATE distribution_jobs
        SET state = 'transferring', updated_at = ?1
        WHERE id = (SELECT job_id FROM distribution_items WHERE id = ?2)
          AND state = 'queued'
        "#,
    )
    .bind(&now_text)
    .bind(&task_id)
    .execute(&mut *tx)
    .await?;
    let row = sqlx::query(
        r#"
        SELECT
            item.id,
            item.job_id,
            item.track_id,
            track.title,
            album.title AS album_title,
            (
                SELECT GROUP_CONCAT(artist.name, ', ')
                FROM track_artists track_artist
                JOIN artists artist ON artist.id = track_artist.artist_id
                WHERE track_artist.track_id = track.id
                  AND track_artist.role = 'primary'
                ORDER BY track_artist.position
            ) AS artist_display,
            job.target_root_external_id,
            item.relative_path,
            item.extension,
            item.expected_size_bytes,
            item.expected_quick_hash,
            item.attempt_count
        FROM distribution_items item
        JOIN distribution_jobs job ON job.id = item.job_id
        JOIN tracks track ON track.id = item.track_id
        LEFT JOIN albums album ON album.id = track.album_id
        WHERE item.id = ?1
        "#,
    )
    .bind(&task_id)
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Some(DistributionTaskAssignment {
        id: row.try_get("id")?,
        job_id: row.try_get("job_id")?,
        track_id: row.try_get("track_id")?,
        title: row.try_get("title")?,
        artist_display: row.try_get("artist_display")?,
        album_title: row.try_get("album_title")?,
        target_root_external_id: row.try_get("target_root_external_id")?,
        relative_path: row.try_get("relative_path")?,
        extension: row.try_get("extension")?,
        expected_size_bytes: row.try_get("expected_size_bytes")?,
        expected_quick_hash: row.try_get("expected_quick_hash")?,
        attempt_count: row.try_get("attempt_count")?,
        content_path: format!("/distributions/tasks/{task_id}/content"),
    }))
}

pub async fn update_distribution_task(
    pool: &DbPool,
    task_id: &str,
    progress: &DistributionTaskProgress,
) -> Result<DistributionJobSummary> {
    let state = progress.state.trim().to_ascii_lowercase();
    if !matches!(state.as_str(), "progress" | "completed" | "failed") {
        bail!("distribution task state must be progress, completed, or failed");
    }
    let now = Utc::now();
    let now_text = now.to_rfc3339();
    let lease_text = (now + chrono::Duration::minutes(30)).to_rfc3339();
    let mut tx = pool.begin().await?;
    let row = sqlx::query(
        r#"
        SELECT
            item.job_id,
            item.state,
            item.attempt_count,
            item.expected_size_bytes,
            job.target_device_id
        FROM distribution_items item
        JOIN distribution_jobs job ON job.id = item.job_id
        WHERE item.id = ?1
        "#,
    )
    .bind(task_id)
    .fetch_one(&mut *tx)
    .await?;
    let job_id: String = row.try_get("job_id")?;
    let target_device_id: String = row.try_get("target_device_id")?;
    if target_device_id != progress.device_id.trim() {
        bail!("this distribution task belongs to another Client");
    }
    let current_state: String = row.try_get("state")?;
    if matches!(
        current_state.as_str(),
        "completed" | "skipped" | "cancelled"
    ) {
        tx.commit().await?;
        return get_distribution_job(pool, &job_id).await;
    }
    let expected_size: i64 = row.try_get("expected_size_bytes")?;
    let transferred = progress.transferred_bytes.clamp(0, expected_size.max(0));
    match state.as_str() {
        "progress" => {
            sqlx::query(
                r#"
                UPDATE distribution_items
                SET transferred_bytes = MAX(transferred_bytes, ?1),
                    lease_expires_at = ?2,
                    updated_at = ?3
                WHERE id = ?4 AND state = 'transferring'
                "#,
            )
            .bind(transferred)
            .bind(lease_text)
            .bind(&now_text)
            .bind(task_id)
            .execute(&mut *tx)
            .await?;
        }
        "completed" => {
            if transferred != expected_size {
                bail!(
                    "completed distribution size {transferred} does not match expected size {expected_size}"
                );
            }
            sqlx::query(
                r#"
                UPDATE distribution_items
                SET state = 'completed',
                    transferred_bytes = expected_size_bytes,
                    lease_expires_at = NULL,
                    error = NULL,
                    completed_at = ?1,
                    updated_at = ?1
                WHERE id = ?2
                "#,
            )
            .bind(&now_text)
            .bind(task_id)
            .execute(&mut *tx)
            .await?;
        }
        "failed" => {
            let attempt_count: i64 = row.try_get("attempt_count")?;
            let retry = progress.retryable && attempt_count < 3;
            sqlx::query(
                r#"
                UPDATE distribution_items
                SET state = ?1,
                    transferred_bytes = ?2,
                    lease_expires_at = NULL,
                    error = ?3,
                    completed_at = CASE WHEN ?1 = 'failed' THEN ?4 ELSE NULL END,
                    updated_at = ?4
                WHERE id = ?5
                "#,
            )
            .bind(if retry { "queued" } else { "failed" })
            .bind(transferred)
            .bind(
                progress
                    .error
                    .as_deref()
                    .unwrap_or("Client delivery failed"),
            )
            .bind(&now_text)
            .bind(task_id)
            .execute(&mut *tx)
            .await?;
        }
        _ => unreachable!(),
    }
    refresh_distribution_job_totals(&mut tx, &job_id, &now_text).await?;
    tx.commit().await?;
    get_distribution_job(pool, &job_id).await
}

pub async fn distribution_content_source(
    pool: &DbPool,
    task_id: &str,
    device_id: &str,
) -> Result<DistributionContentSource> {
    let row = sqlx::query(
        r#"
        SELECT COALESCE(item.content_file_path, file.path) AS path, item.extension
        FROM distribution_items item
        JOIN distribution_jobs job ON job.id = item.job_id
        JOIN files file ON file.id = item.source_file_id
        WHERE item.id = ?1
          AND job.target_device_id = ?2
          AND job.state <> 'cancelled'
          AND item.state = 'transferring'
          AND file.deleted_at IS NULL
        "#,
    )
    .bind(task_id)
    .bind(device_id)
    .fetch_one(pool)
    .await?;
    Ok(DistributionContentSource {
        path: row.try_get("path")?,
        extension: row.try_get("extension")?,
    })
}
