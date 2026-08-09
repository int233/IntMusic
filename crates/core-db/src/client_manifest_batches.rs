use super::*;

pub(crate) async fn prepare_client_manifest_batch(
    pool: &DbPool,
    device_id: &str,
    root_external_id: &str,
    scan_id: &str,
    batch_id: Option<&str>,
) -> Result<bool> {
    sqlx::query(
        r#"
        DELETE FROM client_library_manifest_batches
        WHERE device_id = ?1 AND root_external_id = ?2 AND scan_id <> ?3
        "#,
    )
    .bind(device_id)
    .bind(root_external_id)
    .bind(scan_id)
    .execute(pool)
    .await?;

    let Some(batch_id) = batch_id else {
        return Ok(false);
    };
    Ok(sqlx::query_scalar::<_, i64>(
        r#"
        SELECT EXISTS (
            SELECT 1
            FROM client_library_manifest_batches
            WHERE device_id = ?1
              AND root_external_id = ?2
              AND scan_id = ?3
              AND batch_id = ?4
        )
        "#,
    )
    .bind(device_id)
    .bind(root_external_id)
    .bind(scan_id)
    .bind(batch_id)
    .fetch_one(pool)
    .await?
        != 0)
}

pub(crate) async fn record_client_manifest_batch(
    pool: &DbPool,
    manifest: &ClientLibraryManifestRequest,
    accepted_files: i64,
    processed_at: &str,
) -> Result<bool> {
    let device_id = manifest.device_id.trim();
    let root_external_id = manifest.root.external_id.trim();
    let scan_id = manifest.scan_id.trim();
    let inserted = if let Some(batch_id) = manifest.batch_id.as_deref().map(str::trim) {
        sqlx::query(
            r#"
            INSERT OR IGNORE INTO client_library_manifest_batches (
                device_id, root_external_id, scan_id, batch_id,
                accepted_files, complete, processed_at
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
        )
        .bind(device_id)
        .bind(root_external_id)
        .bind(scan_id)
        .bind(batch_id)
        .bind(accepted_files)
        .bind(manifest.complete)
        .bind(processed_at)
        .execute(pool)
        .await?
        .rows_affected()
            > 0
    } else {
        true
    };
    if inserted {
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
    }
    Ok(inserted)
}
