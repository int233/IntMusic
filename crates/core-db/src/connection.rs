use super::*;

pub async fn connect(database_file: &Path) -> Result<DbPool> {
    if let Some(parent) = database_file.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .with_context(|| format!("failed to create database directory {}", parent.display()))?;
    }

    let options = SqliteConnectOptions::from_str(&database_file.to_string_lossy())?
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Normal)
        .foreign_keys(true)
        .busy_timeout(Duration::from_secs(30));

    let pool = SqlitePoolOptions::new()
        .max_connections(8)
        .connect_with(options)
        .await
        .with_context(|| format!("failed to open database {}", database_file.display()))?;

    Ok(pool)
}

pub async fn migrate(pool: &DbPool) -> Result<()> {
    repair_line_ending_migration_checksums(pool).await?;
    MIGRATOR
        .run(pool)
        .await
        .context("failed to run database migrations")?;
    audit_library_inventory(pool)
        .await
        .context("failed to audit the library file inventory")?;
    Ok(())
}

pub async fn sync_server_id(pool: &DbPool) -> Result<String> {
    let existing: Option<String> =
        sqlx::query_scalar("SELECT server_id FROM core_sync_state WHERE id = 1")
            .fetch_optional(pool)
            .await?
            .flatten();
    if let Some(server_id) = existing.filter(|value| !value.trim().is_empty()) {
        return Ok(server_id);
    }

    let server_id = Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT INTO core_sync_state (id, server_id, created_at, updated_at)
        VALUES (1, ?1, ?2, ?2)
        ON CONFLICT(id) DO UPDATE SET
            server_id = COALESCE(NULLIF(core_sync_state.server_id, ''), excluded.server_id),
            updated_at = excluded.updated_at
        "#,
    )
    .bind(&server_id)
    .bind(&now)
    .execute(pool)
    .await?;
    Ok(
        sqlx::query_scalar("SELECT server_id FROM core_sync_state WHERE id = 1")
            .fetch_one(pool)
            .await?,
    )
}

pub async fn sync_cursor(pool: &DbPool) -> Result<u64> {
    let cursor: i64 =
        sqlx::query_scalar("SELECT COALESCE(MAX(cursor), 0) FROM client_sync_changes")
            .fetch_one(pool)
            .await?;
    Ok(u64::try_from(cursor.max(0))?)
}

pub async fn append_sync_change(pool: &DbPool, scope: &str, reason: &str) -> Result<u64> {
    let result = sqlx::query(
        r#"
        INSERT INTO client_sync_changes (scope, reason, created_at)
        VALUES (?1, ?2, ?3)
        "#,
    )
    .bind(scope)
    .bind(reason)
    .bind(Utc::now().to_rfc3339())
    .execute(pool)
    .await?;
    let cursor = result.last_insert_rowid();
    if cursor % 1_000 == 0 {
        sqlx::query("DELETE FROM client_sync_changes WHERE cursor < ?1")
            .bind(cursor.saturating_sub(50_000))
            .execute(pool)
            .await?;
    }
    Ok(u64::try_from(cursor)?)
}

pub async fn client_sync_changes(
    pool: &DbPool,
    after: u64,
    limit: u32,
) -> Result<Vec<ClientSyncChange>> {
    let rows = sqlx::query(
        r#"
        SELECT cursor, scope, reason, created_at
        FROM client_sync_changes
        WHERE cursor > ?1
        ORDER BY cursor
        LIMIT ?2
        "#,
    )
    .bind(i64::try_from(after)?)
    .bind(i64::from(limit.clamp(1, 2_000)))
    .fetch_all(pool)
    .await?;
    rows.into_iter()
        .map(|row| {
            Ok(ClientSyncChange {
                cursor: u64::try_from(row.try_get::<i64, _>("cursor")?)?,
                scope: row.try_get("scope")?,
                reason: row.try_get("reason")?,
                created_at: parse_datetime(row.try_get::<String, _>("created_at")?)?,
            })
        })
        .collect()
}

pub async fn client_sync_detail_ids(
    pool: &DbPool,
    kind: &str,
    after_id: i64,
    limit: u32,
) -> Result<Vec<i64>> {
    let table = match kind {
        "track" => "tracks",
        "album" => "albums",
        "artist" => "artists",
        "playlist" => "playlists",
        _ => bail!("unsupported Client sync detail kind"),
    };
    // `table` is selected from the closed list above; values remain bound.
    Ok(sqlx::query_scalar::<_, i64>(
        format!("SELECT id FROM {table} WHERE id > ?1 ORDER BY id LIMIT ?2").as_str(),
    )
    .bind(after_id.max(0))
    .bind(i64::from(limit.clamp(1, 200)))
    .fetch_all(pool)
    .await?)
}

async fn repair_line_ending_migration_checksums(pool: &DbPool) -> Result<()> {
    let migrations_table_exists: Option<i64> = sqlx::query_scalar(
        r#"
        SELECT 1
        FROM sqlite_master
        WHERE type = 'table' AND name = '_sqlx_migrations'
        "#,
    )
    .fetch_optional(pool)
    .await?;
    if migrations_table_exists.is_none() {
        return Ok(());
    }

    for migration in MIGRATOR.iter() {
        let stored_checksum: Option<Vec<u8>> = sqlx::query_scalar(
            r#"
            SELECT checksum
            FROM _sqlx_migrations
            WHERE version = ?1 AND success = 1
            "#,
        )
        .bind(migration.version)
        .fetch_optional(pool)
        .await?;
        let Some(stored_checksum) = stored_checksum else {
            continue;
        };
        if stored_checksum.as_slice() == migration.checksum.as_ref() {
            continue;
        }

        let line_ending_checksums = migration_line_ending_checksums(&migration.sql);
        if !line_ending_checksums
            .iter()
            .any(|checksum| checksum.as_slice() == stored_checksum)
        {
            continue;
        }

        let result = sqlx::query(
            r#"
            UPDATE _sqlx_migrations
            SET checksum = ?1
            WHERE version = ?2 AND success = 1 AND checksum = ?3
            "#,
        )
        .bind(migration.checksum.as_ref())
        .bind(migration.version)
        .bind(&stored_checksum)
        .execute(pool)
        .await?;
        if result.rows_affected() == 1 {
            warn!(
                version = migration.version,
                "repaired a migration checksum changed only by line endings"
            );
        }
    }
    Ok(())
}

pub(super) fn migration_line_ending_checksums(sql: &str) -> [Vec<u8>; 2] {
    let lf = sql.replace("\r\n", "\n").replace('\r', "\n");
    let crlf = lf.replace('\n', "\r\n");
    [
        Sha384::digest(lf.as_bytes()).to_vec(),
        Sha384::digest(crlf.as_bytes()).to_vec(),
    ]
}
