use super::*;

pub async fn claim_distribution_transcode_task(
    pool: &DbPool,
) -> Result<Option<DistributionTranscodeTask>> {
    let now = Utc::now();
    let now_text = now.to_rfc3339();
    let lease_text = (now + chrono::Duration::hours(6)).to_rfc3339();
    let mut tx = pool.begin_with("BEGIN IMMEDIATE").await?;
    let expired_jobs = sqlx::query_scalar::<_, String>(
        r#"
        SELECT DISTINCT job_id
        FROM distribution_items
        WHERE state = 'transcoding'
          AND transcode_lease_expires_at IS NOT NULL
          AND transcode_lease_expires_at < ?1
        "#,
    )
    .bind(&now_text)
    .fetch_all(&mut *tx)
    .await?;
    sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = CASE
                WHEN transcode_attempt_count >= 3 THEN 'failed'
                ELSE 'preparing'
            END,
            error = CASE
                WHEN transcode_attempt_count >= 3
                    THEN 'transcoding lease expired after 3 attempts'
                ELSE error
            END,
            transcode_lease_expires_at = NULL,
            updated_at = ?1,
            completed_at = CASE
                WHEN transcode_attempt_count >= 3 THEN ?1
                ELSE NULL
            END
        WHERE state = 'transcoding'
          AND transcode_lease_expires_at IS NOT NULL
          AND transcode_lease_expires_at < ?1
        "#,
    )
    .bind(&now_text)
    .execute(&mut *tx)
    .await?;
    for job_id in expired_jobs {
        refresh_distribution_job_totals(&mut tx, &job_id, &now_text).await?;
    }

    let candidate: Option<String> = sqlx::query_scalar(
        r#"
        SELECT item.id
        FROM distribution_items item
        JOIN distribution_jobs job ON job.id = item.job_id
        WHERE item.state = 'preparing'
          AND job.state NOT IN ('cancelled', 'completed', 'completed_with_errors')
        ORDER BY job.created_at, item.created_at
        LIMIT 1
        "#,
    )
    .fetch_optional(&mut *tx)
    .await?;
    let Some(task_id) = candidate else {
        tx.commit().await?;
        return Ok(None);
    };
    let claimed = sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = 'transcoding',
            transcode_attempt_count = transcode_attempt_count + 1,
            transcode_claimed_at = ?1,
            transcode_lease_expires_at = ?2,
            error = NULL,
            updated_at = ?1
        WHERE id = ?3 AND state = 'preparing'
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
    let row = sqlx::query(
        r#"
        SELECT
            item.id,
            item.job_id,
            job.quality,
            COALESCE(item.content_file_path, file.path) AS source_path,
            file.size_bytes,
            file.modified_at,
            file.quick_hash
        FROM distribution_items item
        JOIN distribution_jobs job ON job.id = item.job_id
        JOIN files file ON file.id = item.source_file_id
        WHERE item.id = ?1
          AND file.deleted_at IS NULL
          AND file.availability_state = 'ready'
        "#,
    )
    .bind(&task_id)
    .fetch_one(&mut *tx)
    .await?;
    let quick_hash: Option<String> = row.try_get("quick_hash")?;
    let source_signature = quick_hash
        .filter(|value| !value.trim().is_empty())
        .map(|value| format!("quick:{value}"))
        .unwrap_or_else(|| {
            format!(
                "file:{}:{}:{}",
                row.try_get::<i64, _>("size_bytes").unwrap_or_default(),
                row.try_get::<String, _>("modified_at").unwrap_or_default(),
                row.try_get::<String, _>("source_path").unwrap_or_default()
            )
        });
    let task = DistributionTranscodeTask {
        id: row.try_get("id")?,
        job_id: row.try_get("job_id")?,
        quality: row.try_get("quality")?,
        source_path: row.try_get("source_path")?,
        source_signature,
    };
    tx.commit().await?;
    Ok(Some(task))
}

pub async fn complete_distribution_transcode_task(
    pool: &DbPool,
    task_id: &str,
    content_file_path: &Path,
    extension: &str,
    expected_size_bytes: i64,
    expected_quick_hash: &str,
) -> Result<DistributionJobSummary> {
    if expected_size_bytes <= 0 {
        bail!("a transcoded file must not be empty");
    }
    let extension = extension
        .trim()
        .trim_start_matches('.')
        .to_ascii_lowercase();
    if extension.is_empty() || !extension.chars().all(|value| value.is_ascii_alphanumeric()) {
        bail!("invalid transcoded file extension");
    }
    let now = Utc::now().to_rfc3339();
    let mut tx = pool.begin().await?;
    let job_id: String = sqlx::query_scalar("SELECT job_id FROM distribution_items WHERE id = ?1")
        .bind(task_id)
        .fetch_one(&mut *tx)
        .await?;
    let updated = sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = 'queued',
            content_file_path = ?1,
            extension = ?2,
            expected_size_bytes = ?3,
            expected_quick_hash = ?4,
            transferred_bytes = 0,
            transcode_lease_expires_at = NULL,
            error = NULL,
            updated_at = ?5
        WHERE id = ?6 AND state = 'transcoding'
        "#,
    )
    .bind(normalize_path(content_file_path))
    .bind(extension)
    .bind(expected_size_bytes)
    .bind(expected_quick_hash)
    .bind(&now)
    .bind(task_id)
    .execute(&mut *tx)
    .await?;
    if updated.rows_affected() == 0 {
        bail!("the distribution transcode task is no longer active");
    }
    refresh_distribution_job_totals(&mut tx, &job_id, &now).await?;
    tx.commit().await?;
    get_distribution_job(pool, &job_id).await
}

pub async fn active_distribution_content_paths(pool: &DbPool) -> Result<Vec<String>> {
    Ok(sqlx::query_scalar(
        r#"
        SELECT DISTINCT content_file_path
        FROM distribution_items
        WHERE content_file_path IS NOT NULL
          AND state IN ('preparing', 'transcoding', 'queued', 'transferring')
        "#,
    )
    .fetch_all(pool)
    .await?)
}

pub async fn distribution_content_paths_for_job(
    pool: &DbPool,
    job_id: &str,
) -> Result<Vec<String>> {
    Ok(sqlx::query_scalar(
        r#"
        SELECT DISTINCT content_file_path
        FROM distribution_items
        WHERE job_id = ?1 AND content_file_path IS NOT NULL
        "#,
    )
    .bind(job_id)
    .fetch_all(pool)
    .await?)
}

pub async fn fail_distribution_transcode_task(
    pool: &DbPool,
    task_id: &str,
    retryable: bool,
    error: &str,
) -> Result<DistributionJobSummary> {
    let now = Utc::now().to_rfc3339();
    let mut tx = pool.begin().await?;
    let row = sqlx::query(
        r#"
        SELECT job_id, state, transcode_attempt_count
        FROM distribution_items
        WHERE id = ?1
        "#,
    )
    .bind(task_id)
    .fetch_one(&mut *tx)
    .await?;
    let job_id: String = row.try_get("job_id")?;
    let state: String = row.try_get("state")?;
    if state != "transcoding" {
        tx.commit().await?;
        return get_distribution_job(pool, &job_id).await;
    }
    let attempts: i64 = row.try_get("transcode_attempt_count")?;
    let should_retry = retryable && attempts < 3;
    let message = error.chars().take(2_000).collect::<String>();
    sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = ?1,
            transcode_lease_expires_at = NULL,
            error = ?2,
            completed_at = CASE WHEN ?1 = 'failed' THEN ?3 ELSE NULL END,
            updated_at = ?3
        WHERE id = ?4
        "#,
    )
    .bind(if should_retry { "preparing" } else { "failed" })
    .bind(message)
    .bind(&now)
    .bind(task_id)
    .execute(&mut *tx)
    .await?;
    refresh_distribution_job_totals(&mut tx, &job_id, &now).await?;
    tx.commit().await?;
    get_distribution_job(pool, &job_id).await
}

pub async fn cancel_distribution_job(
    pool: &DbPool,
    job_id: &str,
) -> Result<DistributionJobSummary> {
    let now = Utc::now().to_rfc3339();
    let mut tx = pool.begin().await?;
    let updated = sqlx::query(
        r#"
        UPDATE distribution_jobs
        SET state = 'cancelled', updated_at = ?1, completed_at = ?1
        WHERE id = ?2
          AND state NOT IN ('completed', 'completed_with_errors', 'cancelled')
        "#,
    )
    .bind(&now)
    .bind(job_id)
    .execute(&mut *tx)
    .await?;
    if updated.rows_affected() > 0 {
        sqlx::query(
            r#"
            UPDATE distribution_items
            SET state = 'cancelled',
                lease_expires_at = NULL,
                source_upload_lease_expires_at = NULL,
                transcode_lease_expires_at = NULL,
                updated_at = ?1
            WHERE job_id = ?2
              AND state IN (
                  'awaiting_source', 'source_uploading',
                  'preparing', 'transcoding', 'queued', 'transferring'
              )
            "#,
        )
        .bind(&now)
        .bind(job_id)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    get_distribution_job(pool, job_id).await
}

pub(crate) async fn refresh_distribution_job_totals(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    job_id: &str,
    now: &str,
) -> Result<()> {
    let totals = sqlx::query(
        r#"
        SELECT
            COUNT(*) AS total_items,
            COALESCE(SUM(CASE WHEN state IN ('completed', 'skipped') THEN 1 ELSE 0 END), 0)
                AS completed_items,
            COALESCE(SUM(CASE WHEN state = 'failed' THEN 1 ELSE 0 END), 0)
                AS failed_items,
            COALESCE(SUM(CASE
                WHEN state = 'skipped' THEN 0
                WHEN state = 'completed' THEN expected_size_bytes
                ELSE MIN(transferred_bytes, expected_size_bytes)
            END), 0) AS transferred_bytes,
            COALESCE(SUM(CASE
                WHEN state = 'skipped' THEN 0
                ELSE expected_size_bytes
            END), 0) AS total_bytes,
            COALESCE(SUM(CASE WHEN state IN ('preparing', 'transcoding') THEN 1 ELSE 0 END), 0)
                AS preparing_items,
            COALESCE(SUM(CASE WHEN state IN ('awaiting_source', 'source_uploading') THEN 1 ELSE 0 END), 0)
                AS source_items,
            COALESCE(SUM(CASE WHEN state = 'transferring' THEN 1 ELSE 0 END), 0)
                AS transferring_items,
            MAX(CASE WHEN state = 'failed' THEN error ELSE NULL END) AS error
        FROM distribution_items
        WHERE job_id = ?1
        "#,
    )
    .bind(job_id)
    .fetch_one(&mut **tx)
    .await?;
    let total_items: i64 = totals.try_get("total_items")?;
    let completed_items: i64 = totals.try_get("completed_items")?;
    let failed_items: i64 = totals.try_get("failed_items")?;
    let terminal = completed_items + failed_items >= total_items;
    let state = if terminal && failed_items > 0 {
        "completed_with_errors"
    } else if terminal {
        "completed"
    } else if totals.try_get::<i64, _>("transferring_items")? > 0 {
        "transferring"
    } else if totals.try_get::<i64, _>("preparing_items")? > 0 {
        "preparing"
    } else if totals.try_get::<i64, _>("source_items")? > 0 {
        "awaiting_source"
    } else {
        "queued"
    };
    sqlx::query(
        r#"
        UPDATE distribution_jobs
        SET state = ?1,
            completed_items = ?2,
            failed_items = ?3,
            transferred_bytes = ?4,
            total_bytes = ?5,
            error = ?6,
            updated_at = ?7,
            completed_at = CASE WHEN ?8 THEN ?7 ELSE NULL END
        WHERE id = ?9 AND state <> 'cancelled'
        "#,
    )
    .bind(state)
    .bind(completed_items)
    .bind(failed_items)
    .bind(totals.try_get::<i64, _>("transferred_bytes")?)
    .bind(totals.try_get::<i64, _>("total_bytes")?)
    .bind(totals.try_get::<Option<String>, _>("error")?)
    .bind(now)
    .bind(terminal)
    .bind(job_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

pub(crate) fn row_to_distribution_job(
    row: sqlx::sqlite::SqliteRow,
) -> Result<DistributionJobSummary> {
    let created_at: String = row.try_get("created_at")?;
    let updated_at: String = row.try_get("updated_at")?;
    let completed_at: Option<String> = row.try_get("completed_at")?;
    Ok(DistributionJobSummary {
        id: row.try_get("id")?,
        target_device_id: row.try_get("target_device_id")?,
        target_device_name: row.try_get("target_device_name")?,
        target_root_external_id: row.try_get("target_root_external_id")?,
        target_root_name: row.try_get("target_root_name")?,
        quality: row.try_get("quality")?,
        state: row.try_get("state")?,
        total_items: row.try_get("total_items")?,
        completed_items: row.try_get("completed_items")?,
        failed_items: row.try_get("failed_items")?,
        total_bytes: row.try_get("total_bytes")?,
        transferred_bytes: row.try_get("transferred_bytes")?,
        error: row.try_get("error")?,
        created_at: parse_datetime(created_at)?,
        updated_at: parse_datetime(updated_at)?,
        completed_at: completed_at.map(parse_datetime).transpose()?,
    })
}

pub(crate) fn distribution_profile_extension(quality: &str) -> Result<Option<&'static str>> {
    match quality {
        "original" => Ok(None),
        "flac" | "lossless" => Ok(Some("flac")),
        "aac-256" | "high" | "aac-160" | "balanced" | "aac-96" | "data-saver" => Ok(Some("m4a")),
        "opus-160" | "opus-96" => Ok(Some("opus")),
        _ => bail!("unknown distribution quality profile {quality}"),
    }
}

pub(crate) fn distribution_relative_path(
    artist: &str,
    album: &str,
    title: &str,
    disc_number: Option<i64>,
    track_number: Option<i64>,
    extension: &str,
) -> String {
    let artist = safe_distribution_path_component(artist, "Unknown Artist");
    let album = safe_distribution_path_component(album, "Unknown Album");
    let title = safe_distribution_path_component(title, "Unknown Track");
    let extension = extension
        .chars()
        .filter(|value| value.is_ascii_alphanumeric())
        .collect::<String>()
        .to_ascii_lowercase();
    let extension = if extension.is_empty() {
        "audio".to_string()
    } else {
        extension
    };
    let prefix = match (disc_number, track_number) {
        (Some(disc), Some(track)) if disc > 1 => format!("{disc}-{track:02}"),
        (_, Some(track)) => format!("{track:02}"),
        _ => "00".to_string(),
    };
    format!("{artist}/{album}/{prefix} - {title}.{extension}")
}

pub(crate) fn safe_distribution_path_component(value: &str, fallback: &str) -> String {
    let mut safe = value
        .chars()
        .map(|character| {
            if character.is_control()
                || matches!(
                    character,
                    '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*'
                )
            {
                '_'
            } else {
                character
            }
        })
        .collect::<String>();
    safe = safe.trim().trim_matches('.').trim().to_string();
    if safe.is_empty() {
        safe = fallback.to_string();
    }
    if safe.chars().count() > 120 {
        safe = safe.chars().take(120).collect();
    }
    let reserved = safe
        .split('.')
        .next()
        .unwrap_or_default()
        .to_ascii_uppercase();
    if matches!(
        reserved.as_str(),
        "CON"
            | "PRN"
            | "AUX"
            | "NUL"
            | "COM1"
            | "COM2"
            | "COM3"
            | "COM4"
            | "COM5"
            | "COM6"
            | "COM7"
            | "COM8"
            | "COM9"
            | "LPT1"
            | "LPT2"
            | "LPT3"
            | "LPT4"
            | "LPT5"
            | "LPT6"
            | "LPT7"
            | "LPT8"
            | "LPT9"
    ) {
        safe.insert(0, '_');
    }
    safe
}
