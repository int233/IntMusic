use super::*;

const RETAINED_EVENT_COUNT: u64 = 50_000;
const PRUNE_INTERVAL: u64 = 512;

#[derive(Debug)]
pub struct EventJournalPage {
    pub events: Vec<EventEnvelope>,
    pub scanned_cursor: u64,
    pub has_more: bool,
    pub requires_snapshot: bool,
}

pub async fn event_journal_cursor(pool: &DbPool) -> Result<u64> {
    let cursor: i64 = sqlx::query_scalar("SELECT COALESCE(MAX(cursor), 0) FROM core_event_journal")
        .fetch_one(pool)
        .await?;
    Ok(cursor.max(0) as u64)
}

pub async fn record_event(pool: &DbPool, event: &EventEnvelope) -> Result<()> {
    let cursor = event
        .cursor
        .ok_or_else(|| anyhow::anyhow!("journaled event is missing its cursor"))?;
    let envelope_json = serde_json::to_string(event)?;
    sqlx::query(
        r#"
        INSERT OR IGNORE INTO core_event_journal (
            cursor, event_id, event_type, envelope_json, created_at
        ) VALUES (?1, ?2, ?3, ?4, ?5)
        "#,
    )
    .bind(i64::try_from(cursor).context("event cursor exceeds SQLite INTEGER range")?)
    .bind(event.id.to_string())
    .bind(&event.event_type)
    .bind(envelope_json)
    .bind(event.time.to_rfc3339())
    .execute(pool)
    .await?;

    if cursor.is_multiple_of(PRUNE_INTERVAL) {
        let retained_floor = cursor.saturating_sub(RETAINED_EVENT_COUNT);
        sqlx::query("DELETE FROM core_event_journal WHERE cursor <= ?1")
            .bind(i64::try_from(retained_floor).unwrap_or(i64::MAX))
            .execute(pool)
            .await?;
    }
    Ok(())
}

pub async fn replay_events(
    pool: &DbPool,
    after_cursor: u64,
    limit: u32,
) -> Result<EventJournalPage> {
    let limit = limit.clamp(1, 1_000);
    let minimum_cursor: Option<i64> =
        sqlx::query_scalar("SELECT MIN(cursor) FROM core_event_journal")
            .fetch_one(pool)
            .await?;
    let requires_snapshot = after_cursor > 0
        && minimum_cursor
            .is_some_and(|minimum| minimum.max(0) as u64 > after_cursor.saturating_add(1));
    let rows = sqlx::query(
        r#"
        SELECT cursor, envelope_json
        FROM core_event_journal
        WHERE cursor > ?1
        ORDER BY cursor
        LIMIT ?2
        "#,
    )
    .bind(i64::try_from(after_cursor).unwrap_or(i64::MAX))
    .bind(i64::from(limit) + 1)
    .fetch_all(pool)
    .await?;
    let has_more = rows.len() > limit as usize;
    let mut events = Vec::with_capacity(rows.len().min(limit as usize));
    let mut scanned_cursor = after_cursor;
    for row in rows.into_iter().take(limit as usize) {
        let cursor: i64 = row.try_get("cursor")?;
        let envelope_json: String = row.try_get("envelope_json")?;
        let event: EventEnvelope = serde_json::from_str(&envelope_json)?;
        scanned_cursor = cursor.max(0) as u64;
        events.push(event);
    }
    Ok(EventJournalPage {
        events,
        scanned_cursor,
        has_more,
        requires_snapshot,
    })
}
