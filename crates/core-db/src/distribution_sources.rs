use super::*;

#[derive(Debug, Clone)]
pub struct DistributionSourceUploadExpectation {
    pub expected_size_bytes: i64,
    pub expected_quick_hash: Option<String>,
    pub extension: String,
}

pub async fn claim_distribution_source_task(
    pool: &DbPool,
    device_id: &str,
) -> Result<Option<DistributionSourceTaskAssignment>> {
    let device_id = device_id.trim();
    if device_id.is_empty() || device_id.len() > 200 {
        bail!("device_id must contain between 1 and 200 characters");
    }
    let now = Utc::now();
    let now_text = now.to_rfc3339();
    let lease_text = (now + chrono::Duration::minutes(30)).to_rfc3339();
    let mut tx = pool.begin().await?;
    let expired_jobs = sqlx::query_scalar::<_, String>(
        r#"
        SELECT DISTINCT job_id
        FROM distribution_items
        WHERE source_device_id = ?1
          AND state = 'source_uploading'
          AND source_upload_lease_expires_at IS NOT NULL
          AND source_upload_lease_expires_at < ?2
        "#,
    )
    .bind(device_id)
    .bind(&now_text)
    .fetch_all(&mut *tx)
    .await?;
    sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = CASE
                WHEN source_upload_attempt_count >= 3 THEN 'failed'
                ELSE 'awaiting_source'
            END,
            error = CASE
                WHEN source_upload_attempt_count >= 3
                    THEN 'source upload lease expired after 3 attempts'
                ELSE error
            END,
            source_upload_lease_expires_at = NULL,
            updated_at = ?1,
            completed_at = CASE
                WHEN source_upload_attempt_count >= 3 THEN ?1
                ELSE NULL
            END
        WHERE source_device_id = ?2
          AND state = 'source_uploading'
          AND source_upload_lease_expires_at IS NOT NULL
          AND source_upload_lease_expires_at < ?1
        "#,
    )
    .bind(&now_text)
    .bind(device_id)
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
        WHERE item.source_device_id = ?1
          AND item.state = 'awaiting_source'
          AND job.state NOT IN ('cancelled', 'completed', 'completed_with_errors')
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
        SET state = 'source_uploading',
            source_upload_attempt_count = source_upload_attempt_count + 1,
            source_upload_claimed_at = ?1,
            source_upload_lease_expires_at = ?2,
            error = NULL,
            updated_at = ?1
        WHERE id = ?3
          AND source_device_id = ?4
          AND state = 'awaiting_source'
        "#,
    )
    .bind(&now_text)
    .bind(&lease_text)
    .bind(&task_id)
    .bind(device_id)
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
            item.track_id,
            track.title,
            item.source_root_external_id,
            item.source_relative_path,
            file.size_bytes,
            file.quick_hash,
            item.source_upload_attempt_count
        FROM distribution_items item
        JOIN tracks track ON track.id = item.track_id
        JOIN files file ON file.id = item.source_file_id
        WHERE item.id = ?1
        "#,
    )
    .bind(&task_id)
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Some(DistributionSourceTaskAssignment {
        id: row.try_get("id")?,
        job_id: row.try_get("job_id")?,
        track_id: row.try_get("track_id")?,
        title: row.try_get("title")?,
        source_root_external_id: row.try_get("source_root_external_id")?,
        source_relative_path: row.try_get("source_relative_path")?,
        expected_size_bytes: row.try_get("size_bytes")?,
        expected_quick_hash: row.try_get("quick_hash")?,
        attempt_count: row.try_get("source_upload_attempt_count")?,
        upload_path: format!("/distributions/source-tasks/{task_id}/content"),
    }))
}

pub async fn distribution_source_upload_expectation(
    pool: &DbPool,
    task_id: &str,
    device_id: &str,
) -> Result<DistributionSourceUploadExpectation> {
    let row = sqlx::query(
        r#"
        SELECT file.size_bytes, file.quick_hash, file.extension
        FROM distribution_items item
        JOIN distribution_jobs job ON job.id = item.job_id
        JOIN files file ON file.id = item.source_file_id
        WHERE item.id = ?1
          AND item.source_device_id = ?2
          AND item.state = 'source_uploading'
          AND job.state <> 'cancelled'
          AND file.deleted_at IS NULL
          AND file.availability_state = 'ready'
        "#,
    )
    .bind(task_id)
    .bind(device_id.trim())
    .fetch_one(pool)
    .await?;
    Ok(DistributionSourceUploadExpectation {
        expected_size_bytes: row.try_get("size_bytes")?,
        expected_quick_hash: row.try_get("quick_hash")?,
        extension: row.try_get("extension")?,
    })
}

pub async fn complete_distribution_source_task(
    pool: &DbPool,
    task_id: &str,
    device_id: &str,
    content_file_path: &Path,
    actual_size_bytes: i64,
    actual_quick_hash: &str,
) -> Result<DistributionJobSummary> {
    let now = Utc::now().to_rfc3339();
    let mut tx = pool.begin().await?;
    let row = sqlx::query(
        r#"
        SELECT
            item.job_id,
            item.source_device_id,
            item.state,
            file.size_bytes,
            file.quick_hash,
            job.quality
        FROM distribution_items item
        JOIN distribution_jobs job ON job.id = item.job_id
        JOIN files file ON file.id = item.source_file_id
        WHERE item.id = ?1
        "#,
    )
    .bind(task_id)
    .fetch_one(&mut *tx)
    .await?;
    let job_id: String = row.try_get("job_id")?;
    if row
        .try_get::<Option<String>, _>("source_device_id")?
        .as_deref()
        != Some(device_id.trim())
    {
        bail!("this source task belongs to another Client");
    }
    if row.try_get::<String, _>("state")? != "source_uploading" {
        bail!("the distribution source task is no longer active");
    }
    let expected_size: i64 = row.try_get("size_bytes")?;
    if actual_size_bytes != expected_size {
        bail!(
            "uploaded source size {actual_size_bytes} does not match expected size {expected_size}"
        );
    }
    let expected_hash: Option<String> = row.try_get("quick_hash")?;
    if expected_hash
        .as_deref()
        .is_some_and(|expected| !expected.eq_ignore_ascii_case(actual_quick_hash))
    {
        bail!("uploaded source failed its content verification");
    }
    let quality: String = row.try_get("quality")?;
    let next_state = if quality == "original" {
        "queued"
    } else {
        "preparing"
    };
    let updated = sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = ?1,
            content_file_path = ?2,
            source_upload_lease_expires_at = NULL,
            error = NULL,
            updated_at = ?3
        WHERE id = ?4 AND state = 'source_uploading'
        "#,
    )
    .bind(next_state)
    .bind(normalize_path(content_file_path))
    .bind(&now)
    .bind(task_id)
    .execute(&mut *tx)
    .await?;
    if updated.rows_affected() == 0 {
        bail!("the distribution source task is no longer active");
    }
    refresh_distribution_job_totals(&mut tx, &job_id, &now).await?;
    tx.commit().await?;
    get_distribution_job(pool, &job_id).await
}

pub async fn fail_distribution_source_task(
    pool: &DbPool,
    task_id: &str,
    device_id: &str,
    retryable: bool,
    error: &str,
) -> Result<DistributionJobSummary> {
    let now = Utc::now().to_rfc3339();
    let mut tx = pool.begin().await?;
    let row = sqlx::query(
        r#"
        SELECT job_id, source_device_id, state, source_upload_attempt_count
        FROM distribution_items
        WHERE id = ?1
        "#,
    )
    .bind(task_id)
    .fetch_one(&mut *tx)
    .await?;
    let job_id: String = row.try_get("job_id")?;
    if row
        .try_get::<Option<String>, _>("source_device_id")?
        .as_deref()
        != Some(device_id.trim())
    {
        bail!("this source task belongs to another Client");
    }
    if row.try_get::<String, _>("state")? != "source_uploading" {
        tx.commit().await?;
        return get_distribution_job(pool, &job_id).await;
    }
    let attempts: i64 = row.try_get("source_upload_attempt_count")?;
    let should_retry = retryable && attempts < 3;
    let message = error.chars().take(2_000).collect::<String>();
    sqlx::query(
        r#"
        UPDATE distribution_items
        SET state = ?1,
            source_upload_lease_expires_at = NULL,
            error = ?2,
            completed_at = CASE WHEN ?1 = 'failed' THEN ?3 ELSE NULL END,
            updated_at = ?3
        WHERE id = ?4
        "#,
    )
    .bind(if should_retry {
        "awaiting_source"
    } else {
        "failed"
    })
    .bind(message)
    .bind(&now)
    .bind(task_id)
    .execute(&mut *tx)
    .await?;
    refresh_distribution_job_totals(&mut tx, &job_id, &now).await?;
    tx.commit().await?;
    get_distribution_job(pool, &job_id).await
}
