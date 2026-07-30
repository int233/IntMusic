use super::*;

pub async fn manage_library_file(
    pool: &DbPool,
    file_id: i64,
    action: &str,
) -> Result<LibraryManagementActionResult> {
    let exists: Option<i64> = sqlx::query_scalar("SELECT id FROM files WHERE id = ?1")
        .bind(file_id)
        .fetch_optional(pool)
        .await?;
    if exists.is_none() {
        bail!("library file was not found");
    }
    let now = Utc::now().to_rfc3339();
    let state = match action.trim() {
        "ignore" => {
            resolve_client_library_file(pool, file_id, "ignore", None, None).await?;
            "ignored"
        }
        "request_rescan" => {
            sqlx::query(
                "UPDATE files SET scan_status = 'needs_attention', scan_message = 'Metadata rescan requested', updated_at = ?1 WHERE id = ?2",
            )
            .bind(&now)
            .bind(file_id)
            .execute(pool)
            .await?;
            open_file_issue(
                pool,
                file_id,
                "rescan_requested",
                Some("Waiting for the owning device to read embedded tags again."),
            )
            .await?;
            "awaiting_rescan"
        }
        "reset" => {
            resolve_client_library_file(pool, file_id, "reset", None, None).await?;
            "awaiting_rescan"
        }
        "restore" => {
            sqlx::query(
                "UPDATE files SET deleted_at = NULL, availability_state = 'missing', scan_status = 'needs_attention', scan_message = 'Restore requested', updated_at = ?1 WHERE id = ?2",
            )
            .bind(&now)
            .bind(file_id)
            .execute(pool)
            .await?;
            open_file_issue(
                pool,
                file_id,
                "rescan_requested",
                Some("Restore is waiting for the owning source to scan this file."),
            )
            .await?;
            "awaiting_rescan"
        }
        "remove" => {
            sqlx::query(
                "UPDATE files SET deleted_at = COALESCE(deleted_at, ?1), availability_state = 'missing', updated_at = ?1 WHERE id = ?2",
            )
            .bind(&now)
            .bind(file_id)
            .execute(pool)
            .await?;
            sqlx::query(
                "UPDATE media_replicas SET availability_state = 'missing', updated_at = ?1 WHERE file_id = ?2",
            )
            .bind(&now)
            .bind(file_id)
            .execute(pool)
            .await?;
            resolve_all_file_issues(pool, file_id).await?;
            "removed"
        }
        _ => bail!("unsupported library file action"),
    };
    Ok(LibraryManagementActionResult {
        target_kind: "file".to_string(),
        target_id: file_id.to_string(),
        action: action.trim().to_string(),
        state: state.to_string(),
    })
}

pub async fn manage_library_files(
    pool: &DbPool,
    file_ids: &[i64],
    action: &str,
) -> Result<LibraryBatchActionResult> {
    let mut file_ids = file_ids
        .iter()
        .copied()
        .filter(|file_id| *file_id > 0)
        .collect::<Vec<_>>();
    file_ids.sort_unstable();
    file_ids.dedup();
    if file_ids.is_empty() {
        bail!("select at least one library file");
    }
    if file_ids.len() > 500 {
        bail!("a library batch action cannot exceed 500 files");
    }
    let action = action.trim();
    if !matches!(
        action,
        "ignore" | "request_rescan" | "reset" | "restore" | "remove"
    ) {
        bail!("unsupported library file action");
    }
    let mut updated = 0_u32;
    for file_id in &file_ids {
        let row = sqlx::query(
            r#"
            SELECT
                file.scan_status,
                file.deleted_at,
                EXISTS(
                    SELECT 1 FROM client_file_resolutions resolution
                    WHERE resolution.file_id = file.id
                ) AS has_resolution
            FROM files file
            WHERE file.id = ?1
            "#,
        )
        .bind(file_id)
        .fetch_optional(pool)
        .await?
        .context("library file was not found")?;
        let scan_status: String = row.try_get("scan_status")?;
        let deleted_at: Option<String> = row.try_get("deleted_at")?;
        let has_resolution = row.try_get::<i64, _>("has_resolution")? != 0;
        let eligible = match action {
            "ignore" => deleted_at.is_none() && scan_status != "ignored",
            "request_rescan" => deleted_at.is_none(),
            "reset" => scan_status == "ignored" || has_resolution,
            "restore" => deleted_at.is_some(),
            "remove" => deleted_at.is_none(),
            _ => false,
        };
        if eligible {
            manage_library_file(pool, *file_id, action).await?;
            updated = updated.saturating_add(1);
        }
    }
    Ok(LibraryBatchActionResult {
        target_kind: "files".to_string(),
        action: action.to_string(),
        requested: u32::try_from(file_ids.len()).unwrap_or(u32::MAX),
        updated,
    })
}

pub async fn manage_library_device(
    pool: &DbPool,
    device_id: &str,
    action: &str,
) -> Result<LibraryManagementActionResult> {
    let device_id = device_id.trim();
    if device_id.is_empty() || device_id == "core" {
        bail!("the Core device cannot be retired");
    }
    let now = Utc::now().to_rfc3339();
    let state = match action.trim() {
        "retire" => {
            let result = sqlx::query(
                "UPDATE devices SET retired_at = COALESCE(retired_at, ?1) WHERE id = ?2",
            )
            .bind(&now)
            .bind(device_id)
            .execute(pool)
            .await?;
            if result.rows_affected() == 0 {
                bail!("library device was not found");
            }
            sqlx::query(
                "UPDATE library_roots SET enabled = 0, retired_at = COALESCE(retired_at, ?1), updated_at = ?1 WHERE owner_device_id = ?2",
            )
            .bind(&now)
            .bind(device_id)
            .execute(pool)
            .await?;
            sqlx::query(
                "UPDATE media_replicas SET availability_state = 'retired', updated_at = ?1 WHERE device_id = ?2",
            )
            .bind(&now)
            .bind(device_id)
            .execute(pool)
            .await?;
            "retired"
        }
        "restore" => {
            let result = sqlx::query(
                "UPDATE devices SET retired_at = NULL, removed_at = NULL WHERE id = ?1",
            )
            .bind(device_id)
            .execute(pool)
            .await?;
            if result.rows_affected() == 0 {
                bail!("library device was not found");
            }
            sqlx::query(
                "UPDATE library_roots SET enabled = 1, retired_at = NULL, updated_at = ?1 WHERE owner_device_id = ?2",
            )
            .bind(&now)
            .bind(device_id)
            .execute(pool)
            .await?;
            sqlx::query(
                "UPDATE media_replicas SET availability_state = 'missing', updated_at = ?1 WHERE device_id = ?2",
            )
            .bind(&now)
            .bind(device_id)
            .execute(pool)
            .await?;
            "offline"
        }
        "remove" => {
            let result = sqlx::query(
                "UPDATE devices SET retired_at = COALESCE(retired_at, ?1), removed_at = COALESCE(removed_at, ?1) WHERE id = ?2",
            )
            .bind(&now)
            .bind(device_id)
            .execute(pool)
            .await?;
            if result.rows_affected() == 0 {
                bail!("library device was not found");
            }
            sqlx::query(
                "UPDATE library_roots SET enabled = 0, retired_at = COALESCE(retired_at, ?1), updated_at = ?1 WHERE owner_device_id = ?2",
            )
            .bind(&now)
            .bind(device_id)
            .execute(pool)
            .await?;
            sqlx::query(
                r#"
                UPDATE files
                SET deleted_at = COALESCE(deleted_at, ?1),
                    availability_state = 'missing',
                    updated_at = ?1
                WHERE library_root_id IN (
                    SELECT id FROM library_roots WHERE owner_device_id = ?2
                )
                "#,
            )
            .bind(&now)
            .bind(device_id)
            .execute(pool)
            .await?;
            sqlx::query(
                "UPDATE media_replicas SET availability_state = 'retired', updated_at = ?1 WHERE device_id = ?2",
            )
            .bind(&now)
            .bind(device_id)
            .execute(pool)
            .await?;
            sqlx::query(
                r#"
                UPDATE library_file_issues
                SET state = 'resolved', resolved_at = ?1, updated_at = ?1
                WHERE state = 'open' AND file_id IN (
                    SELECT file.id
                    FROM files file
                    JOIN library_roots root ON root.id = file.library_root_id
                    WHERE root.owner_device_id = ?2
                )
                "#,
            )
            .bind(&now)
            .bind(device_id)
            .execute(pool)
            .await?;
            "removed"
        }
        _ => bail!("unsupported library device action"),
    };
    Ok(LibraryManagementActionResult {
        target_kind: "device".to_string(),
        target_id: device_id.to_string(),
        action: action.trim().to_string(),
        state: state.to_string(),
    })
}

pub async fn manage_library_source(
    pool: &DbPool,
    root_id: i64,
    action: &str,
) -> Result<LibraryManagementActionResult> {
    let now = Utc::now().to_rfc3339();
    let state = match action.trim() {
        "retire" => {
            let result = sqlx::query(
                "UPDATE library_roots SET enabled = 0, retired_at = COALESCE(retired_at, ?1), updated_at = ?1 WHERE id = ?2",
            )
            .bind(&now)
            .bind(root_id)
            .execute(pool)
            .await?;
            if result.rows_affected() == 0 {
                bail!("library source was not found");
            }
            sqlx::query(
                "UPDATE media_replicas SET availability_state = 'retired', updated_at = ?1 WHERE library_root_id = ?2",
            )
            .bind(&now)
            .bind(root_id)
            .execute(pool)
            .await?;
            "retired"
        }
        "restore" => {
            let result = sqlx::query(
                "UPDATE library_roots SET enabled = 1, retired_at = NULL, removed_at = NULL, updated_at = ?1 WHERE id = ?2",
            )
            .bind(&now)
            .bind(root_id)
            .execute(pool)
            .await?;
            if result.rows_affected() == 0 {
                bail!("library source was not found");
            }
            sqlx::query(
                "UPDATE media_replicas SET availability_state = 'missing', updated_at = ?1 WHERE library_root_id = ?2",
            )
            .bind(&now)
            .bind(root_id)
            .execute(pool)
            .await?;
            "offline"
        }
        "remove" => {
            let root = sqlx::query(
                "SELECT root_kind, owner_device_id, external_id FROM library_roots WHERE id = ?1",
            )
            .bind(root_id)
            .fetch_optional(pool)
            .await?
            .context("library source was not found")?;
            let root_kind: String = root.try_get("root_kind")?;
            if root_kind != "client" {
                bail!("Core library sources must be removed from the music folder settings");
            }
            let owner_device_id: Option<String> = root.try_get("owner_device_id")?;
            let external_id: Option<String> = root.try_get("external_id")?;
            let mut transaction = pool.begin().await?;
            sqlx::query(
                "UPDATE library_roots SET enabled = 0, retired_at = COALESCE(retired_at, ?1), removed_at = COALESCE(removed_at, ?1), updated_at = ?1 WHERE id = ?2",
            )
            .bind(&now)
            .bind(root_id)
            .execute(&mut *transaction)
            .await?;
            sqlx::query(
                r#"
                UPDATE files
                SET deleted_at = COALESCE(deleted_at, ?1),
                    availability_state = 'missing',
                    updated_at = ?1
                WHERE library_root_id = ?2
                "#,
            )
            .bind(&now)
            .bind(root_id)
            .execute(&mut *transaction)
            .await?;
            sqlx::query(
                "UPDATE media_replicas SET availability_state = 'retired', updated_at = ?1 WHERE library_root_id = ?2",
            )
            .bind(&now)
            .bind(root_id)
            .execute(&mut *transaction)
            .await?;
            sqlx::query(
                r#"
                UPDATE library_file_issues
                SET state = 'resolved', resolved_at = ?1, updated_at = ?1
                WHERE state = 'open' AND file_id IN (
                    SELECT id FROM files WHERE library_root_id = ?2
                )
                "#,
            )
            .bind(&now)
            .bind(root_id)
            .execute(&mut *transaction)
            .await?;
            if let (Some(device_id), Some(root_external_id)) = (owner_device_id, external_id) {
                sqlx::query(
                    "DELETE FROM client_library_sync_state WHERE device_id = ?1 AND root_external_id = ?2",
                )
                .bind(device_id)
                .bind(root_external_id)
                .execute(&mut *transaction)
                .await?;
            }
            transaction.commit().await?;
            "removed"
        }
        _ => bail!("unsupported library source action"),
    };
    Ok(LibraryManagementActionResult {
        target_kind: "source".to_string(),
        target_id: root_id.to_string(),
        action: action.trim().to_string(),
        state: state.to_string(),
    })
}

pub(crate) async fn refresh_file_management_issues(pool: &DbPool, file_id: i64) -> Result<()> {
    let status: String = sqlx::query_scalar("SELECT scan_status FROM files WHERE id = ?1")
        .bind(file_id)
        .fetch_one(pool)
        .await?;
    resolve_all_file_issues(pool, file_id).await?;
    match status.as_str() {
        "tag_parse_error" => {
            let message: Option<String> =
                sqlx::query_scalar("SELECT scan_message FROM files WHERE id = ?1")
                    .bind(file_id)
                    .fetch_one(pool)
                    .await?;
            open_file_issue(pool, file_id, "tag_parse_error", message.as_deref()).await?;
        }
        "needs_attention" => {
            let message: Option<String> =
                sqlx::query_scalar("SELECT scan_message FROM files WHERE id = ?1")
                    .bind(file_id)
                    .fetch_one(pool)
                    .await?;
            open_file_issue(pool, file_id, "missing_required_tags", message.as_deref()).await?;
        }
        _ => {}
    }
    Ok(())
}

pub async fn audit_library_inventory(pool: &DbPool) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT INTO library_file_issues (
            file_id, issue_kind, state, message, created_at, updated_at
        )
        SELECT
            id,
            CASE scan_status
                WHEN 'tag_parse_error' THEN 'tag_parse_error'
                ELSE 'missing_required_tags'
            END,
            'open',
            scan_message,
            ?1,
            ?1
        FROM files
        WHERE deleted_at IS NULL
          AND scan_status IN ('needs_attention', 'tag_parse_error')
        ON CONFLICT(file_id, issue_kind) DO UPDATE SET
            state = 'open',
            message = excluded.message,
            updated_at = excluded.updated_at,
            resolved_at = NULL
        "#,
    )
    .bind(&now)
    .execute(pool)
    .await?;
    Ok(())
}

async fn open_file_issue(
    pool: &DbPool,
    file_id: i64,
    issue_kind: &str,
    message: Option<&str>,
) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT INTO library_file_issues (
            file_id, issue_kind, state, message, created_at, updated_at
        )
        VALUES (?1, ?2, 'open', ?3, ?4, ?4)
        ON CONFLICT(file_id, issue_kind) DO UPDATE SET
            state = 'open',
            message = excluded.message,
            updated_at = excluded.updated_at,
            resolved_at = NULL
        "#,
    )
    .bind(file_id)
    .bind(issue_kind)
    .bind(message)
    .bind(&now)
    .execute(pool)
    .await?;
    Ok(())
}

async fn resolve_all_file_issues(pool: &DbPool, file_id: i64) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        UPDATE library_file_issues
        SET state = 'resolved', resolved_at = ?1, updated_at = ?1
        WHERE file_id = ?2 AND state = 'open'
        "#,
    )
    .bind(now)
    .bind(file_id)
    .execute(pool)
    .await?;
    Ok(())
}
