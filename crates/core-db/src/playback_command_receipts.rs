use super::*;

const RETAINED_COMMAND_COUNT: i64 = 50_000;
const PRUNE_INTERVAL: i64 = 512;

#[derive(Debug, Clone)]
pub struct PlaybackCommandReceipt {
    pub zone_id: String,
    pub action: String,
    pub response_json: String,
}

pub async fn playback_command_receipt(
    pool: &DbPool,
    origin_client_id: &str,
    intent_id: &str,
) -> Result<Option<PlaybackCommandReceipt>> {
    let row = sqlx::query(
        r#"
        SELECT zone_id, action, response_json
        FROM playback_command_receipts
        WHERE origin_client_id = ?1 AND intent_id = ?2
        "#,
    )
    .bind(origin_client_id)
    .bind(intent_id)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|row| PlaybackCommandReceipt {
        zone_id: row.get("zone_id"),
        action: row.get("action"),
        response_json: row.get("response_json"),
    }))
}

pub async fn record_playback_command_receipt(
    pool: &DbPool,
    origin_client_id: &str,
    intent_id: &str,
    zone_id: &str,
    action: &str,
    response_json: &str,
) -> Result<()> {
    let result = sqlx::query(
        r#"
        INSERT INTO playback_command_receipts (
            origin_client_id, intent_id, zone_id, action,
            response_json, created_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        ON CONFLICT(origin_client_id, intent_id) DO NOTHING
        "#,
    )
    .bind(origin_client_id)
    .bind(intent_id)
    .bind(zone_id)
    .bind(action)
    .bind(response_json)
    .bind(Utc::now().to_rfc3339())
    .execute(pool)
    .await?;
    if result.rows_affected() > 0 && result.last_insert_rowid() % PRUNE_INTERVAL == 0 {
        sqlx::query(
            r#"
            DELETE FROM playback_command_receipts
            WHERE rowid <= (
                SELECT MAX(rowid) - ?1 FROM playback_command_receipts
            )
            "#,
        )
        .bind(RETAINED_COMMAND_COUNT)
        .execute(pool)
        .await?;
    }
    Ok(())
}
