use std::collections::HashSet;

use super::*;
use protocol::{PlaybackQueueItemV3, PlaybackRepeatModeV3, PlaybackSessionModeV3};

#[derive(Debug, Clone)]
pub struct PlaybackSessionMetaV3 {
    pub session_id: Uuid,
    pub zone_id: String,
    pub owner_device_id: String,
    pub epoch: u64,
    pub revision: u64,
    pub event_cursor: u64,
    pub mode: PlaybackSessionModeV3,
    pub last_command_id: Option<Uuid>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct PlaybackQueueStateV3 {
    pub current_item_id: Option<Uuid>,
    pub shuffle_seed: u64,
    pub items: Vec<PlaybackQueueItemV3>,
}

pub async fn ensure_playback_session_v3(
    pool: &DbPool,
    zone_id: &str,
    owner_device_id: &str,
    event_cursor: u64,
) -> Result<PlaybackSessionMetaV3> {
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT OR IGNORE INTO playback_sessions_v3 (
            zone_id, session_id, owner_device_id, epoch, revision,
            event_cursor, created_at, updated_at
        ) VALUES (?1, ?2, ?3, 1, 0, ?4, ?5, ?5)
        "#,
    )
    .bind(zone_id)
    .bind(Uuid::now_v7().to_string())
    .bind(owner_device_id)
    .bind(to_sql_u64(event_cursor, "event cursor")?)
    .bind(&now)
    .execute(pool)
    .await?;

    let current = playback_session_meta_v3(pool, zone_id)
        .await?
        .ok_or_else(|| anyhow::anyhow!("failed to create playback session for {zone_id}"))?;
    if current.owner_device_id == owner_device_id {
        return Ok(current);
    }

    sqlx::query(
        r#"
        UPDATE playback_sessions_v3
        SET owner_device_id = ?2,
            epoch = epoch + 1,
            revision = revision + 1,
            event_cursor = MAX(event_cursor, ?3),
            last_command_id = NULL,
            updated_at = ?4
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .bind(owner_device_id)
    .bind(to_sql_u64(event_cursor, "event cursor")?)
    .bind(now)
    .execute(pool)
    .await?;
    playback_session_meta_v3(pool, zone_id)
        .await?
        .ok_or_else(|| anyhow::anyhow!("playback session {zone_id} disappeared"))
}

pub async fn playback_session_meta_v3(
    pool: &DbPool,
    zone_id: &str,
) -> Result<Option<PlaybackSessionMetaV3>> {
    let row = sqlx::query(
        r#"
        SELECT session_id, zone_id, owner_device_id, epoch, revision,
               event_cursor, repeat_mode, shuffle, stop_after_current,
               last_command_id, updated_at
        FROM playback_sessions_v3
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .fetch_optional(pool)
    .await?;
    row.map(row_to_session_meta_v3).transpose()
}

pub async fn synchronize_playback_session_revision_v3(
    pool: &DbPool,
    zone_id: &str,
) -> Result<PlaybackSessionMetaV3> {
    let queue_revision: i64 =
        sqlx::query_scalar("SELECT revision FROM playback_queues WHERE zone_id = ?1")
            .bind(zone_id)
            .fetch_one(pool)
            .await?;
    sqlx::query(
        r#"
        UPDATE playback_sessions_v3
        SET revision = MAX(revision, ?2),
            updated_at = CASE WHEN revision < ?2 THEN ?3 ELSE updated_at END
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .bind(queue_revision.max(0))
    .bind(Utc::now().to_rfc3339())
    .execute(pool)
    .await?;
    playback_session_meta_v3(pool, zone_id)
        .await?
        .ok_or_else(|| anyhow::anyhow!("playback session {zone_id} disappeared"))
}

pub async fn advance_playback_session_v3(
    pool: &DbPool,
    zone_id: &str,
    command_id: Uuid,
    event_cursor: u64,
) -> Result<PlaybackSessionMetaV3> {
    let result = sqlx::query(
        r#"
        UPDATE playback_sessions_v3
        SET revision = revision + 1,
            event_cursor = MAX(event_cursor, ?2),
            last_command_id = ?3,
            updated_at = ?4
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .bind(to_sql_u64(event_cursor, "event cursor")?)
    .bind(command_id.to_string())
    .bind(Utc::now().to_rfc3339())
    .execute(pool)
    .await?;
    if result.rows_affected() == 0 {
        anyhow::bail!("playback session {zone_id} does not exist");
    }
    playback_session_meta_v3(pool, zone_id)
        .await?
        .ok_or_else(|| anyhow::anyhow!("playback session {zone_id} disappeared"))
}

pub async fn update_playback_session_cursor_v3(
    pool: &DbPool,
    zone_id: &str,
    event_cursor: u64,
) -> Result<()> {
    sqlx::query(
        r#"
        UPDATE playback_sessions_v3
        SET event_cursor = MAX(event_cursor, ?2), updated_at = ?3
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .bind(to_sql_u64(event_cursor, "event cursor")?)
    .bind(Utc::now().to_rfc3339())
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn update_playback_session_mode_v3(
    pool: &DbPool,
    zone_id: &str,
    mode: PlaybackSessionModeV3,
) -> Result<()> {
    sqlx::query(
        r#"
        UPDATE playback_sessions_v3
        SET repeat_mode = ?2, shuffle = ?3, stop_after_current = ?4, updated_at = ?5
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .bind(repeat_mode_as_str(mode.repeat))
    .bind(i64::from(mode.shuffle))
    .bind(i64::from(mode.stop_after_current))
    .bind(Utc::now().to_rfc3339())
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn playback_queue_state_v3(pool: &DbPool, zone_id: &str) -> Result<PlaybackQueueStateV3> {
    ensure_playback_queue(pool, zone_id).await?;
    backfill_playback_queue_item_ids_v3(pool, zone_id).await?;
    let metadata =
        sqlx::query("SELECT current_index, shuffle_seed FROM playback_queues WHERE zone_id = ?1")
            .bind(zone_id)
            .fetch_one(pool)
            .await?;
    let rows = sqlx::query(
        r#"
        SELECT stable_item_id, track_id, added_by_device_id, added_at
        FROM playback_queue_items
        WHERE zone_id = ?1
        ORDER BY position
        "#,
    )
    .bind(zone_id)
    .fetch_all(pool)
    .await?;
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        items.push(PlaybackQueueItemV3 {
            item_id: Uuid::parse_str(&row.try_get::<String, _>("stable_item_id")?)
                .context("stored playback queue item UUID is invalid")?,
            track_id: row.try_get("track_id")?,
            added_by_device_id: row
                .try_get::<Option<String>, _>("added_by_device_id")?
                .unwrap_or_else(|| "legacy".to_string()),
            added_at: parse_timestamp(&row.try_get::<String, _>("added_at")?)?,
        });
    }
    let current_item_id = metadata
        .try_get::<Option<i64>, _>("current_index")?
        .and_then(|index| usize::try_from(index).ok())
        .and_then(|index| items.get(index))
        .map(|item| item.item_id);
    Ok(PlaybackQueueStateV3 {
        current_item_id,
        shuffle_seed: metadata.try_get::<i64, _>("shuffle_seed")?.max(1) as u64,
        items,
    })
}

pub async fn replace_playback_queue_v3(
    pool: &DbPool,
    zone_id: &str,
    items: &[PlaybackQueueItemV3],
    current_item_id: Option<Uuid>,
) -> Result<()> {
    validate_queue_items(items)?;
    ensure_playback_queue(pool, zone_id).await?;
    let current_index = current_item_id
        .map(|item_id| {
            items
                .iter()
                .position(|item| item.item_id == item_id)
                .map(|index| index as i64)
                .ok_or_else(|| anyhow::anyhow!("start queue item {item_id} does not exist"))
        })
        .transpose()?;
    let mut tx = pool.begin().await?;
    write_queue_items(&mut tx, zone_id, items).await?;
    sqlx::query(
        r#"
        UPDATE playback_queues
        SET revision = revision + 1,
            current_index = ?2,
            shuffle_seed = CASE WHEN shuffle_seed >= 2147483646 THEN 1 ELSE shuffle_seed + 1 END,
            updated_at = ?3
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .bind(current_index)
    .bind(Utc::now().to_rfc3339())
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(())
}

pub async fn set_playback_queue_current_item_v3(
    pool: &DbPool,
    zone_id: &str,
    item_id: Uuid,
) -> Result<i64> {
    backfill_playback_queue_item_ids_v3(pool, zone_id).await?;
    let row = sqlx::query(
        "SELECT position, track_id FROM playback_queue_items WHERE zone_id = ?1 AND stable_item_id = ?2",
    )
    .bind(zone_id)
    .bind(item_id.to_string())
    .fetch_optional(pool)
    .await?
    .ok_or_else(|| anyhow::anyhow!("queue item {item_id} does not exist"))?;
    let position: i64 = row.try_get("position")?;
    sqlx::query(
        r#"
        UPDATE playback_queues
        SET current_index = ?2, revision = revision + 1, updated_at = ?3
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .bind(position)
    .bind(Utc::now().to_rfc3339())
    .execute(pool)
    .await?;
    Ok(row.try_get("track_id")?)
}

async fn backfill_playback_queue_item_ids_v3(pool: &DbPool, zone_id: &str) -> Result<()> {
    let rows = sqlx::query(
        "SELECT id FROM playback_queue_items WHERE zone_id = ?1 AND stable_item_id IS NULL",
    )
    .bind(zone_id)
    .fetch_all(pool)
    .await?;
    for row in rows {
        sqlx::query(
            "UPDATE playback_queue_items SET stable_item_id = ?2, added_by_device_id = COALESCE(added_by_device_id, 'legacy') WHERE id = ?1",
        )
        .bind(row.try_get::<i64, _>("id")?)
        .bind(Uuid::now_v7().to_string())
        .execute(pool)
        .await?;
    }
    Ok(())
}

async fn write_queue_items(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    zone_id: &str,
    items: &[PlaybackQueueItemV3],
) -> Result<()> {
    sqlx::query("DELETE FROM playback_queue_items WHERE zone_id = ?1")
        .bind(zone_id)
        .execute(&mut **tx)
        .await?;
    for (position, item) in items.iter().enumerate() {
        sqlx::query(
            r#"
            INSERT INTO playback_queue_items (
                zone_id, position, track_id, added_at, stable_item_id, added_by_device_id
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            "#,
        )
        .bind(zone_id)
        .bind(position as i64)
        .bind(item.track_id)
        .bind(item.added_at.to_rfc3339())
        .bind(item.item_id.to_string())
        .bind(&item.added_by_device_id)
        .execute(&mut **tx)
        .await?;
    }
    Ok(())
}

fn validate_queue_items(items: &[PlaybackQueueItemV3]) -> Result<()> {
    let mut ids = HashSet::with_capacity(items.len());
    for item in items {
        if !ids.insert(item.item_id) {
            anyhow::bail!("queue item {} occurs more than once", item.item_id);
        }
    }
    Ok(())
}

fn row_to_session_meta_v3(row: sqlx::sqlite::SqliteRow) -> Result<PlaybackSessionMetaV3> {
    Ok(PlaybackSessionMetaV3 {
        session_id: Uuid::parse_str(&row.try_get::<String, _>("session_id")?)
            .context("stored playback session UUID is invalid")?,
        zone_id: row.try_get("zone_id")?,
        owner_device_id: row.try_get("owner_device_id")?,
        epoch: row.try_get::<i64, _>("epoch")?.max(0) as u64,
        revision: row.try_get::<i64, _>("revision")?.max(0) as u64,
        event_cursor: row.try_get::<i64, _>("event_cursor")?.max(0) as u64,
        mode: PlaybackSessionModeV3 {
            repeat: parse_repeat_mode(&row.try_get::<String, _>("repeat_mode")?),
            shuffle: row.try_get::<i64, _>("shuffle")? != 0,
            stop_after_current: row.try_get::<i64, _>("stop_after_current")? != 0,
        },
        last_command_id: row
            .try_get::<Option<String>, _>("last_command_id")?
            .map(|value| Uuid::parse_str(&value))
            .transpose()
            .context("stored playback command UUID is invalid")?,
        updated_at: parse_timestamp(&row.try_get::<String, _>("updated_at")?)?,
    })
}

fn parse_timestamp(value: &str) -> Result<DateTime<Utc>> {
    Ok(DateTime::parse_from_rfc3339(value)
        .with_context(|| format!("invalid stored timestamp {value}"))?
        .with_timezone(&Utc))
}

fn to_sql_u64(value: u64, label: &str) -> Result<i64> {
    i64::try_from(value).with_context(|| format!("{label} exceeds SQLite INTEGER range"))
}

fn repeat_mode_as_str(mode: PlaybackRepeatModeV3) -> &'static str {
    match mode {
        PlaybackRepeatModeV3::Off => "off",
        PlaybackRepeatModeV3::One => "one",
        PlaybackRepeatModeV3::All => "all",
    }
}

fn parse_repeat_mode(value: &str) -> PlaybackRepeatModeV3 {
    match value {
        "one" => PlaybackRepeatModeV3::One,
        "all" => PlaybackRepeatModeV3::All,
        _ => PlaybackRepeatModeV3::Off,
    }
}
