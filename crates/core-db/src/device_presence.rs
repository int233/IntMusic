use super::*;

/// Registration is a heartbeat even on devices with no library folders.
pub async fn register_device_presence(
    pool: &DbPool,
    device_id: &str,
    name: &str,
    platform: &str,
) -> Result<()> {
    let now = Utc::now();
    sqlx::query(
        r#"
        INSERT INTO devices (id, name, platform, token_hash, created_at, last_seen_at, online_until)
        VALUES (?1, ?2, ?3, '', ?4, ?4, ?5)
        ON CONFLICT(id) DO UPDATE SET name = excluded.name, platform = excluded.platform,
            last_seen_at = excluded.last_seen_at, online_until = excluded.online_until
    "#,
    )
    .bind(device_id)
    .bind(name)
    .bind(platform)
    .bind(now.to_rfc3339())
    .bind((now + chrono::Duration::seconds(protocol::DEVICE_ONLINE_SECONDS)).to_rfc3339())
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn renew_device_presence(pool: &DbPool, device_id: &str) -> Result<()> {
    let now = Utc::now();
    sqlx::query("UPDATE devices SET last_seen_at = ?2, online_until = ?3 WHERE id = ?1")
        .bind(device_id)
        .bind(now.to_rfc3339())
        .bind((now + chrono::Duration::seconds(protocol::DEVICE_ONLINE_SECONDS)).to_rfc3339())
        .execute(pool)
        .await?;
    Ok(())
}

/// Fence decoder commands and presence leases left by a previous Core process.
pub async fn reset_runtime_authority(pool: &DbPool) -> Result<()> {
    let mut tx = pool.begin().await?;
    sqlx::query("UPDATE playback_sessions_v3 SET epoch = epoch + 1, revision = revision + 1, last_command_id = NULL").execute(&mut *tx).await?;
    sqlx::query("UPDATE devices SET online_until = NULL")
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(())
}
