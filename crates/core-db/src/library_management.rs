use std::collections::BTreeMap;

use super::*;

#[derive(Debug, Clone, Default)]
pub struct LibraryFileQuery {
    pub search: Option<String>,
    pub device_id: Option<String>,
    pub root_id: Option<i64>,
    pub extension: Option<String>,
    pub status: Option<String>,
    pub issue: Option<String>,
    pub file_id: Option<i64>,
    pub limit: u32,
    pub offset: u32,
}

const INVENTORY_CTE: &str = r#"
WITH inventory AS (
    SELECT
        file.id AS file_id,
        file.library_root_id AS root_id,
        root.root_kind,
        root.external_id AS root_external_id,
        COALESCE(NULLIF(root.display_name, ''), root.path) AS root_name,
        root.path_hint AS root_path_hint,
        root.enabled AS root_enabled,
        root.retired_at AS root_retired_at,
        COALESCE(root.owner_device_id, 'core') AS device_id,
        COALESCE(device.name, 'Core local') AS device_name,
        device.platform AS device_platform,
        device.last_seen_at AS device_last_seen_at,
        device.retired_at AS device_retired_at,
        file.relative_path,
        file.extension,
        file.size_bytes,
        file.modified_at,
        file.codec,
        file.sample_rate,
        file.channels,
        file.duration_ms,
        file.bitrate,
        file.bit_depth,
        file.quick_hash,
        file.content_hash,
        file.scan_status,
        file.scan_message,
        file.availability_state,
        file.deleted_at,
        replica.media_variant_id,
        replica.last_verified_at,
        resolution.resolution_kind,
        COALESCE(
            direct_track.id,
            (
                SELECT MIN(link.track_id)
                FROM media_replicas linked_replica
                JOIN release_track_media_variants relation
                  ON relation.media_variant_id = linked_replica.media_variant_id
                JOIN legacy_track_catalog_links link
                  ON link.release_track_id = relation.release_track_id
                WHERE linked_replica.file_id = file.id
            )
        ) AS catalog_track_id,
        (
            SELECT GROUP_CONCAT(issue.issue_kind, ',')
            FROM library_file_issues issue
            WHERE issue.file_id = file.id AND issue.state = 'open'
        ) AS issue_kinds
    FROM files file
    JOIN library_roots root ON root.id = file.library_root_id
    LEFT JOIN devices device ON device.id = root.owner_device_id
    LEFT JOIN tracks direct_track ON direct_track.file_id = file.id
    LEFT JOIN media_replicas replica ON replica.file_id = file.id
    LEFT JOIN client_file_resolutions resolution ON resolution.file_id = file.id
)
"#;

const INVENTORY_FILTERS: &str = r#"
WHERE (?1 IS NULL OR lower(
        inventory.relative_path || ' ' ||
        inventory.root_name || ' ' ||
        inventory.device_name || ' ' ||
        COALESCE(track.title, '') || ' ' ||
        COALESCE(album.title, '')
    ) LIKE ?1)
  AND (?2 IS NULL OR inventory.device_id = ?2)
  AND (?3 IS NULL OR inventory.root_id = ?3)
  AND (?4 IS NULL OR lower(inventory.extension) = ?4)
  AND (?5 IS NULL OR ?5 = 'all'
       OR (?5 = 'attention' AND inventory.issue_kinds IS NOT NULL)
       OR (?5 = 'ignored' AND inventory.scan_status = 'ignored')
       OR (?5 = 'unresolved' AND inventory.catalog_track_id IS NULL
            AND inventory.scan_status <> 'ignored')
       OR (?5 = 'removed' AND inventory.deleted_at IS NOT NULL)
       OR (?5 = 'retired' AND (
            inventory.root_retired_at IS NOT NULL
            OR inventory.device_retired_at IS NOT NULL
       ))
       OR (?5 = 'missing' AND inventory.deleted_at IS NULL
            AND inventory.availability_state <> 'ready')
       OR (?5 = 'offline' AND inventory.root_kind = 'client'
            AND inventory.deleted_at IS NULL
            AND inventory.root_retired_at IS NULL
            AND inventory.device_retired_at IS NULL
            AND (
                inventory.device_last_seen_at IS NULL
                OR datetime(inventory.device_last_seen_at) < datetime('now', '-5 minutes')
            ))
       OR (?5 = 'available' AND inventory.deleted_at IS NULL
            AND inventory.availability_state = 'ready'
            AND inventory.root_enabled = 1
            AND inventory.root_retired_at IS NULL
            AND inventory.device_retired_at IS NULL
            AND (
                inventory.root_kind = 'core'
                OR datetime(inventory.device_last_seen_at) >= datetime('now', '-5 minutes')
            )))
  AND (?6 IS NULL OR ',' || COALESCE(inventory.issue_kinds, '') || ','
        LIKE '%,' || ?6 || ',%')
  AND (?7 IS NULL OR inventory.file_id = ?7)
"#;

pub async fn library_management_summary(pool: &DbPool) -> Result<LibraryManagementSummary> {
    let row = sqlx::query(
        r#"
        SELECT
            COUNT(*) AS total_files,
            COALESCE(SUM(CASE WHEN file.deleted_at IS NULL THEN 1 ELSE 0 END), 0)
                AS active_files,
            COALESCE(SUM(CASE
                WHEN file.deleted_at IS NULL
                 AND file.availability_state = 'ready'
                 AND root.enabled = 1
                 AND root.retired_at IS NULL
                 AND device.retired_at IS NULL
                 AND (
                    root.root_kind = 'core'
                    OR datetime(device.last_seen_at) >= datetime('now', '-5 minutes')
                 )
                THEN 1 ELSE 0 END), 0) AS available_files,
            COALESCE(SUM(CASE
                WHEN file.deleted_at IS NULL AND (
                    file.availability_state <> 'ready'
                    OR root.enabled = 0
                    OR root.retired_at IS NOT NULL
                    OR device.retired_at IS NOT NULL
                    OR (
                        root.root_kind = 'client'
                        AND (
                            device.last_seen_at IS NULL
                            OR datetime(device.last_seen_at) < datetime('now', '-5 minutes')
                        )
                    )
                )
                THEN 1 ELSE 0 END), 0) AS unavailable_files,
            COALESCE(SUM(CASE WHEN file.deleted_at IS NULL AND EXISTS (
                SELECT 1 FROM library_file_issues issue
                WHERE issue.file_id = file.id AND issue.state = 'open'
            ) THEN 1 ELSE 0 END), 0) AS attention_files,
            COALESCE(SUM(CASE
                WHEN file.deleted_at IS NULL AND file.scan_status = 'ignored'
                THEN 1 ELSE 0 END), 0) AS ignored_files,
            COALESCE(SUM(CASE
                WHEN file.deleted_at IS NULL THEN file.size_bytes ELSE 0 END), 0)
                AS total_bytes
        FROM files file
        JOIN library_roots root ON root.id = file.library_root_id
        LEFT JOIN devices device ON device.id = root.owner_device_id
        "#,
    )
    .fetch_one(pool)
    .await?;
    let device_count: i64 = sqlx::query_scalar("SELECT COUNT(*) + 1 FROM devices")
        .fetch_one(pool)
        .await?;
    let source_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM library_roots")
        .fetch_one(pool)
        .await?;
    let retired_device_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM devices WHERE retired_at IS NOT NULL")
            .fetch_one(pool)
            .await?;
    Ok(LibraryManagementSummary {
        total_files: row.try_get("total_files")?,
        active_files: row.try_get("active_files")?,
        available_files: row.try_get("available_files")?,
        unavailable_files: row.try_get("unavailable_files")?,
        attention_files: row.try_get("attention_files")?,
        ignored_files: row.try_get("ignored_files")?,
        total_bytes: row.try_get("total_bytes")?,
        device_count,
        source_count,
        retired_device_count,
    })
}

pub async fn list_library_files(
    pool: &DbPool,
    query: &LibraryFileQuery,
) -> Result<LibraryFilePage> {
    let search = query
        .search
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| format!("%{}%", value.to_lowercase()));
    let device_id = normalized_filter(query.device_id.as_deref());
    let extension = normalized_filter(query.extension.as_deref()).map(str::to_lowercase);
    let status = normalized_filter(query.status.as_deref()).map(str::to_lowercase);
    let issue = normalized_filter(query.issue.as_deref()).map(str::to_lowercase);
    let limit = query.limit.clamp(1, 500);
    let offset = query.offset;
    let select_sql = format!(
        r#"
        {INVENTORY_CTE}
        SELECT
            inventory.*,
            track.title AS track_title,
            track.album_id,
            album.title AS album_title,
            (
                SELECT GROUP_CONCAT(name, '; ')
                FROM (
                    SELECT artist.name AS name
                    FROM track_artists credit
                    JOIN artists artist ON artist.id = credit.artist_id
                    WHERE credit.track_id = track.id AND credit.role = 'primary'
                    ORDER BY credit.position
                )
            ) AS artist_display
        FROM inventory
        LEFT JOIN tracks track ON track.id = inventory.catalog_track_id
        LEFT JOIN albums album ON album.id = track.album_id
        {INVENTORY_FILTERS}
        ORDER BY
            CASE WHEN inventory.issue_kinds IS NULL THEN 1 ELSE 0 END,
            inventory.device_name COLLATE NOCASE,
            inventory.root_name COLLATE NOCASE,
            inventory.relative_path COLLATE NOCASE
        LIMIT ?8 OFFSET ?9
        "#,
    );
    let rows = sqlx::query(&select_sql)
        .bind(search.as_deref())
        .bind(device_id)
        .bind(query.root_id)
        .bind(extension.as_deref())
        .bind(status.as_deref())
        .bind(issue.as_deref())
        .bind(query.file_id)
        .bind(i64::from(limit))
        .bind(i64::from(offset))
        .fetch_all(pool)
        .await?;
    let count_sql = format!(
        r#"
        {INVENTORY_CTE}
        SELECT COUNT(*)
        FROM inventory
        LEFT JOIN tracks track ON track.id = inventory.catalog_track_id
        LEFT JOIN albums album ON album.id = track.album_id
        {INVENTORY_FILTERS}
        "#,
    );
    let total: i64 = sqlx::query_scalar(&count_sql)
        .bind(search.as_deref())
        .bind(device_id)
        .bind(query.root_id)
        .bind(extension.as_deref())
        .bind(status.as_deref())
        .bind(issue.as_deref())
        .bind(query.file_id)
        .fetch_one(pool)
        .await?;
    Ok(LibraryFilePage {
        total,
        limit,
        offset,
        items: rows
            .into_iter()
            .map(library_file_from_row)
            .collect::<Result<Vec<_>>>()?,
    })
}

fn normalized_filter(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

fn library_file_from_row(row: sqlx::sqlite::SqliteRow) -> Result<LibraryFileSummary> {
    let root_kind: String = row.try_get("root_kind")?;
    let root_enabled = row.try_get::<i64, _>("root_enabled")? != 0;
    let deleted_at: Option<String> = row.try_get("deleted_at")?;
    let root_retired_at: Option<String> = row.try_get("root_retired_at")?;
    let device_retired_at: Option<String> = row.try_get("device_retired_at")?;
    let availability_state: String = row.try_get("availability_state")?;
    let device_last_seen_at: Option<String> = row.try_get("device_last_seen_at")?;
    let device_online = root_kind == "core"
        || device_last_seen_at
            .as_deref()
            .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
            .map(|value| value.with_timezone(&Utc) >= Utc::now() - chrono::Duration::minutes(5))
            .unwrap_or(false);
    let presence_state = if root_retired_at.is_some() || device_retired_at.is_some() {
        "retired"
    } else if deleted_at.is_some() {
        "removed"
    } else if availability_state != "ready" || !root_enabled {
        "missing"
    } else if !device_online {
        "offline"
    } else {
        "available"
    }
    .to_string();
    let issues = row
        .try_get::<Option<String>, _>("issue_kinds")?
        .unwrap_or_default()
        .split(',')
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();
    let scan_status: String = row.try_get("scan_status")?;
    let resolution_kind: Option<String> = row.try_get("resolution_kind")?;
    let metadata_state = if scan_status == "ignored" {
        "ignored"
    } else if resolution_kind.as_deref() == Some("manual_metadata") {
        "manual"
    } else if issues.iter().any(|value| value == "tag_parse_error") {
        "parse_error"
    } else if issues.iter().any(|value| value == "missing_required_tags") {
        "missing_required"
    } else if issues.iter().any(|value| value == "legacy_unverified") {
        "legacy_unverified"
    } else if issues.iter().any(|value| value == "rescan_requested") {
        "awaiting_rescan"
    } else {
        "verified"
    }
    .to_string();
    let track_id: Option<i64> = row.try_get("catalog_track_id")?;
    let identity_state = if scan_status == "ignored" {
        "ignored"
    } else if track_id.is_some() {
        "identified"
    } else {
        "unresolved"
    }
    .to_string();
    Ok(LibraryFileSummary {
        file_id: row.try_get("file_id")?,
        root_id: row.try_get("root_id")?,
        root_kind,
        root_external_id: row.try_get("root_external_id")?,
        root_name: row.try_get("root_name")?,
        root_path_hint: row.try_get("root_path_hint")?,
        device_id: row.try_get("device_id")?,
        device_name: row.try_get("device_name")?,
        device_platform: row.try_get("device_platform")?,
        relative_path: row.try_get("relative_path")?,
        extension: row.try_get("extension")?,
        size_bytes: row.try_get("size_bytes")?,
        modified_at: row.try_get("modified_at")?,
        codec: row.try_get("codec")?,
        sample_rate: row.try_get("sample_rate")?,
        channels: row.try_get("channels")?,
        duration_ms: row.try_get("duration_ms")?,
        bitrate: row.try_get("bitrate")?,
        bit_depth: row.try_get("bit_depth")?,
        quick_hash: row.try_get("quick_hash")?,
        content_hash: row.try_get("content_hash")?,
        scan_status,
        scan_message: row.try_get("scan_message")?,
        presence_state,
        metadata_state,
        identity_state,
        resolution_kind,
        issues,
        track_id,
        track_title: row.try_get("track_title")?,
        album_id: row.try_get("album_id")?,
        album_title: row.try_get("album_title")?,
        artist_display: row.try_get("artist_display")?,
        media_variant_id: row.try_get("media_variant_id")?,
        last_verified_at: row.try_get("last_verified_at")?,
    })
}

pub async fn library_file_detail(pool: &DbPool, file_id: i64) -> Result<LibraryFileDetail> {
    let page = list_library_files(
        pool,
        &LibraryFileQuery {
            file_id: Some(file_id),
            limit: 1,
            ..Default::default()
        },
    )
    .await?;
    let file = page
        .items
        .into_iter()
        .next()
        .context("library file was not found")?;
    let metadata_json: Option<String> =
        sqlx::query_scalar("SELECT data_json FROM track_metadata_sources WHERE file_id = ?1")
            .bind(file_id)
            .fetch_optional(pool)
            .await?;
    let embedded_metadata = metadata_json
        .map(|value| serde_json::from_str(&value))
        .transpose()
        .context("invalid stored file metadata")?;
    let rows = sqlx::query(
        r#"
        SELECT issue_kind, state, message, created_at, updated_at
        FROM library_file_issues
        WHERE file_id = ?1
        ORDER BY CASE state WHEN 'open' THEN 0 ELSE 1 END, updated_at DESC
        "#,
    )
    .bind(file_id)
    .fetch_all(pool)
    .await?;
    let issues = rows
        .into_iter()
        .map(|row| {
            Ok(LibraryFileIssue {
                issue_kind: row.try_get("issue_kind")?,
                state: row.try_get("state")?,
                message: row.try_get("message")?,
                created_at: parse_datetime(row.try_get::<String, _>("created_at")?)?,
                updated_at: parse_datetime(row.try_get::<String, _>("updated_at")?)?,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(LibraryFileDetail {
        file,
        embedded_metadata,
        issues,
    })
}

pub async fn list_library_devices(pool: &DbPool) -> Result<Vec<LibraryDeviceSummary>> {
    let mut devices = BTreeMap::<String, LibraryDeviceSummary>::new();
    devices.insert(
        "core".to_string(),
        LibraryDeviceSummary {
            device_id: "core".to_string(),
            display_name: "Core local".to_string(),
            platform: None,
            state: "online".to_string(),
            last_seen_at: Some(Utc::now()),
            retired_at: None,
            sources: Vec::new(),
        },
    );
    let device_rows = sqlx::query(
        "SELECT id, name, platform, last_seen_at, retired_at FROM devices ORDER BY name COLLATE NOCASE",
    )
    .fetch_all(pool)
    .await?;
    for row in device_rows {
        let device_id: String = row.try_get("id")?;
        let last_seen_at = row
            .try_get::<Option<String>, _>("last_seen_at")?
            .map(parse_datetime)
            .transpose()?;
        let retired_at = row
            .try_get::<Option<String>, _>("retired_at")?
            .map(parse_datetime)
            .transpose()?;
        let state = device_state(last_seen_at.as_ref(), retired_at.as_ref());
        devices.insert(
            device_id.clone(),
            LibraryDeviceSummary {
                device_id,
                display_name: row.try_get("name")?,
                platform: row.try_get("platform")?,
                state: state.to_string(),
                last_seen_at,
                retired_at,
                sources: Vec::new(),
            },
        );
    }
    let source_rows = sqlx::query(
        r#"
        SELECT
            root.id,
            root.external_id,
            COALESCE(NULLIF(root.display_name, ''), root.path) AS display_name,
            root.path_hint,
            root.root_kind,
            root.owner_device_id,
            root.enabled,
            root.last_seen_at,
            root.retired_at,
            COUNT(file.id) AS file_count,
            COALESCE(SUM(CASE
                WHEN file.deleted_at IS NULL AND file.availability_state = 'ready'
                THEN 1 ELSE 0 END), 0) AS available_file_count,
            COALESCE(SUM(CASE WHEN file.deleted_at IS NULL AND EXISTS (
                SELECT 1 FROM library_file_issues issue
                WHERE issue.file_id = file.id AND issue.state = 'open'
            ) THEN 1 ELSE 0 END), 0) AS attention_file_count,
            COALESCE(SUM(CASE
                WHEN file.deleted_at IS NULL THEN file.size_bytes ELSE 0 END), 0)
                AS total_bytes
        FROM library_roots root
        LEFT JOIN files file ON file.library_root_id = root.id
        GROUP BY root.id
        ORDER BY display_name COLLATE NOCASE
        "#,
    )
    .fetch_all(pool)
    .await?;
    for row in source_rows {
        let device_id = row
            .try_get::<Option<String>, _>("owner_device_id")?
            .unwrap_or_else(|| "core".to_string());
        let last_seen_at = row
            .try_get::<Option<String>, _>("last_seen_at")?
            .map(parse_datetime)
            .transpose()?;
        let retired_at = row
            .try_get::<Option<String>, _>("retired_at")?
            .map(parse_datetime)
            .transpose()?;
        let enabled = row.try_get::<i64, _>("enabled")? != 0;
        let device = devices
            .entry(device_id.clone())
            .or_insert_with(|| LibraryDeviceSummary {
                device_id,
                display_name: "Unknown device".to_string(),
                platform: None,
                state: "offline".to_string(),
                last_seen_at: None,
                retired_at: None,
                sources: Vec::new(),
            });
        let state = if retired_at.is_some() || !enabled {
            "retired"
        } else if device.state == "online" {
            "available"
        } else {
            "offline"
        };
        device.sources.push(LibrarySourceSummary {
            root_id: row.try_get("id")?,
            external_id: row.try_get("external_id")?,
            display_name: row.try_get("display_name")?,
            path_hint: row.try_get("path_hint")?,
            root_kind: row.try_get("root_kind")?,
            state: state.to_string(),
            file_count: row.try_get("file_count")?,
            available_file_count: row.try_get("available_file_count")?,
            attention_file_count: row.try_get("attention_file_count")?,
            total_bytes: row.try_get("total_bytes")?,
            last_seen_at,
            retired_at,
        });
    }
    let mut result = devices.into_values().collect::<Vec<_>>();
    result.sort_by(|left, right| {
        (left.device_id != "core", left.display_name.to_lowercase())
            .cmp(&(right.device_id != "core", right.display_name.to_lowercase()))
    });
    Ok(result)
}

fn device_state(
    last_seen_at: Option<&DateTime<Utc>>,
    retired_at: Option<&DateTime<Utc>>,
) -> &'static str {
    if retired_at.is_some() {
        "retired"
    } else if last_seen_at
        .map(|value| *value >= Utc::now() - chrono::Duration::minutes(5))
        .unwrap_or(false)
    {
        "online"
    } else {
        "offline"
    }
}
