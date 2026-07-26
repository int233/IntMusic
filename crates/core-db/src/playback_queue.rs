use super::*;

pub async fn playback_queue(pool: &DbPool, zone_id: &str) -> Result<PlaybackQueue> {
    ensure_playback_queue(pool, zone_id).await?;
    let metadata =
        sqlx::query("SELECT revision, mode, current_index FROM playback_queues WHERE zone_id = ?1")
            .bind(zone_id)
            .fetch_one(pool)
            .await?;
    let rows = sqlx::query(
        track_select_sql_extra(
            "pqi.id AS queue_item_id, pqi.position AS queue_position,",
            r#"
            JOIN playback_queue_items pqi ON pqi.track_id = t.id
            WHERE pqi.zone_id = ?1
            GROUP BY pqi.id, t.id
            ORDER BY pqi.position
            "#,
        )
        .as_str(),
    )
    .bind(zone_id)
    .fetch_all(pool)
    .await?;
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        let id = row.try_get("queue_item_id")?;
        let position = row.try_get("queue_position")?;
        items.push(PlaybackQueueItem {
            id,
            position,
            track: row_to_track(row)?,
        });
    }
    let current_index = metadata
        .try_get::<Option<i64>, _>("current_index")?
        .filter(|index| *index >= 0 && (*index as usize) < items.len());
    Ok(PlaybackQueue {
        zone_id: zone_id.to_string(),
        revision: metadata.try_get::<i64, _>("revision")?.max(0) as u64,
        mode: parse_playback_mode(&metadata.try_get::<String, _>("mode")?),
        current_index,
        items,
    })
}

pub async fn replace_playback_queue(
    pool: &DbPool,
    zone_id: &str,
    payload: ReplacePlaybackQueue,
) -> Result<PlaybackQueue> {
    ensure_playback_queue(pool, zone_id).await?;
    let mut tx = pool.begin().await?;
    sqlx::query("DELETE FROM playback_queue_items WHERE zone_id = ?1")
        .bind(zone_id)
        .execute(&mut *tx)
        .await?;
    let now = Utc::now().to_rfc3339();
    for (position, track_id) in payload.track_ids.iter().copied().enumerate() {
        sqlx::query(
            r#"
            INSERT INTO playback_queue_items (zone_id, position, track_id, added_at)
            VALUES (?1, ?2, ?3, ?4)
            "#,
        )
        .bind(zone_id)
        .bind(position as i64)
        .bind(track_id)
        .bind(&now)
        .execute(&mut *tx)
        .await?;
    }
    let current_index = payload
        .start_index
        .filter(|index| *index >= 0 && (*index as usize) < payload.track_ids.len());
    let mode = payload
        .mode
        .map(|mode| playback_mode_as_str(&mode).to_string());
    sqlx::query(
        r#"
        UPDATE playback_queues
        SET revision = revision + 1,
            mode = COALESCE(?2, mode),
            current_index = ?3,
            shuffle_seed = CASE
                WHEN shuffle_seed >= 2147483646 THEN 1
                ELSE shuffle_seed + 1
            END,
            updated_at = ?4
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .bind(mode)
    .bind(current_index)
    .bind(&now)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    playback_queue(pool, zone_id).await
}

pub async fn add_playback_queue_items(
    pool: &DbPool,
    zone_id: &str,
    track_ids: Vec<i64>,
    position: Option<i64>,
) -> Result<PlaybackQueue> {
    let queue = playback_queue(pool, zone_id).await?;
    let mut ids = queue
        .items
        .iter()
        .map(|item| item.track.id)
        .collect::<Vec<_>>();
    let insert_at = position
        .unwrap_or(ids.len() as i64)
        .clamp(0, ids.len() as i64) as usize;
    ids.splice(insert_at..insert_at, track_ids);
    let current_track_id = queue
        .current_index
        .and_then(|index| queue.items.get(index as usize))
        .map(|item| item.track.id);
    let current_index = current_track_id
        .and_then(|track_id| ids.iter().position(|id| *id == track_id))
        .map(|index| index as i64);
    replace_playback_queue(
        pool,
        zone_id,
        ReplacePlaybackQueue {
            track_ids: ids,
            start_index: current_index,
            mode: Some(queue.mode),
        },
    )
    .await
}

pub async fn move_playback_queue_item(
    pool: &DbPool,
    zone_id: &str,
    from: i64,
    to: i64,
) -> Result<PlaybackQueue> {
    let queue = playback_queue(pool, zone_id).await?;
    let mut ids = queue
        .items
        .iter()
        .map(|item| item.track.id)
        .collect::<Vec<_>>();
    if from < 0 || from as usize >= ids.len() || to < 0 || to as usize >= ids.len() {
        anyhow::bail!("queue move is outside the queue bounds");
    }
    let current_track_id = queue
        .current_index
        .and_then(|index| queue.items.get(index as usize))
        .map(|item| item.track.id);
    let value = ids.remove(from as usize);
    ids.insert(to as usize, value);
    let current_index = current_track_id
        .and_then(|track_id| ids.iter().position(|id| *id == track_id))
        .map(|index| index as i64);
    replace_playback_queue(
        pool,
        zone_id,
        ReplacePlaybackQueue {
            track_ids: ids,
            start_index: current_index,
            mode: Some(queue.mode),
        },
    )
    .await
}

pub async fn remove_playback_queue_item(
    pool: &DbPool,
    zone_id: &str,
    item_id: i64,
) -> Result<PlaybackQueue> {
    let queue = playback_queue(pool, zone_id).await?;
    let remove_index = queue
        .items
        .iter()
        .position(|item| item.id == item_id)
        .ok_or_else(|| anyhow::anyhow!("queue item {item_id} does not exist"))?;
    let current_track_id = queue
        .current_index
        .and_then(|index| queue.items.get(index as usize))
        .map(|item| item.track.id);
    let mut ids = queue
        .items
        .iter()
        .map(|item| item.track.id)
        .collect::<Vec<_>>();
    ids.remove(remove_index);
    let current_index = current_track_id
        .and_then(|track_id| ids.iter().position(|id| *id == track_id))
        .map(|index| index as i64);
    replace_playback_queue(
        pool,
        zone_id,
        ReplacePlaybackQueue {
            track_ids: ids,
            start_index: current_index,
            mode: Some(queue.mode),
        },
    )
    .await
}

pub async fn set_playback_mode(
    pool: &DbPool,
    zone_id: &str,
    mode: PlaybackMode,
) -> Result<PlaybackQueue> {
    ensure_playback_queue(pool, zone_id).await?;
    sqlx::query(
        r#"
        UPDATE playback_queues
        SET mode = ?2, revision = revision + 1, updated_at = ?3
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .bind(playback_mode_as_str(&mode))
    .bind(Utc::now().to_rfc3339())
    .execute(pool)
    .await?;
    playback_queue(pool, zone_id).await
}

pub async fn set_playback_queue_current_track(
    pool: &DbPool,
    zone_id: &str,
    track_id: i64,
) -> Result<PlaybackQueue> {
    let mut queue = playback_queue(pool, zone_id).await?;
    if !queue.items.iter().any(|item| item.track.id == track_id) {
        queue = add_playback_queue_items(pool, zone_id, vec![track_id], None).await?;
    }
    let index = queue
        .items
        .iter()
        .position(|item| item.track.id == track_id)
        .ok_or_else(|| anyhow::anyhow!("track {track_id} was not added to the queue"))?;
    if queue.current_index == Some(index as i64) {
        return Ok(queue);
    }
    sqlx::query(
        r#"
        UPDATE playback_queues
        SET current_index = ?2, revision = revision + 1, updated_at = ?3
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .bind(index as i64)
    .bind(Utc::now().to_rfc3339())
    .execute(pool)
    .await?;
    playback_queue(pool, zone_id).await
}

pub async fn step_playback_queue(
    pool: &DbPool,
    zone_id: &str,
    previous: bool,
    automatic: bool,
) -> Result<Option<i64>> {
    let queue = playback_queue(pool, zone_id).await?;
    if queue.items.is_empty() || (automatic && queue.mode == PlaybackMode::Single) {
        return Ok(None);
    }
    let current = queue.current_index.unwrap_or(if previous {
        queue.items.len() as i64
    } else {
        -1
    });
    let next = match queue.mode {
        PlaybackMode::RepeatOne if automatic && current >= 0 => current,
        PlaybackMode::Shuffle => {
            let seed = playback_queue_shuffle_seed(pool, zone_id).await?;
            let mut order = (0..queue.items.len()).collect::<Vec<_>>();
            order.sort_by_key(|index| shuffle_key(queue.items[*index].id as u64, seed as u64));
            let cursor = order
                .iter()
                .position(|index| *index as i64 == current)
                .unwrap_or(if previous {
                    0
                } else {
                    order.len().saturating_sub(1)
                });
            let target = if previous {
                cursor.checked_sub(1)
            } else if cursor + 1 < order.len() {
                Some(cursor + 1)
            } else {
                None
            };
            match target {
                Some(target) => order[target] as i64,
                None => order[if previous { order.len() - 1 } else { 0 }] as i64,
            }
        }
        _ => {
            let candidate = if previous { current - 1 } else { current + 1 };
            if candidate >= 0 && (candidate as usize) < queue.items.len() {
                candidate
            } else if queue.mode == PlaybackMode::RepeatAll || !automatic {
                if previous {
                    queue.items.len() as i64 - 1
                } else {
                    0
                }
            } else {
                return Ok(None);
            }
        }
    };
    sqlx::query(
        r#"
        UPDATE playback_queues
        SET current_index = ?2, revision = revision + 1, updated_at = ?3
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .bind(next)
    .bind(Utc::now().to_rfc3339())
    .execute(pool)
    .await?;
    Ok(queue.items.get(next as usize).map(|item| item.track.id))
}

pub async fn zone_volume(pool: &DbPool, zone_id: &str) -> Result<ZoneVolume> {
    ensure_zone_preferences(pool, zone_id).await?;
    let row = sqlx::query(
        r#"
        SELECT
            volume_mode,
            player_volume,
            player_muted,
            system_volume,
            system_muted
        FROM zone_preferences
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .fetch_one(pool)
    .await?;
    let mode = match row.try_get::<String, _>("volume_mode")?.as_str() {
        "system" => VolumeControlMode::System,
        _ => VolumeControlMode::Player,
    };
    let player_volume = row.try_get::<f64, _>("player_volume")? as f32;
    let player_muted = row.try_get::<i64, _>("player_muted")? != 0;
    let system_volume = row
        .try_get::<Option<f64>, _>("system_volume")?
        .map(|value| value as f32);
    let system_muted = row
        .try_get::<Option<i64>, _>("system_muted")?
        .map(|value| value != 0);
    let (volume, muted) = match mode {
        VolumeControlMode::Player => (player_volume, player_muted),
        VolumeControlMode::System => (
            system_volume.unwrap_or(player_volume),
            system_muted.unwrap_or(player_muted),
        ),
    };
    Ok(ZoneVolume {
        zone_id: zone_id.to_string(),
        volume,
        muted,
        mode,
        player_volume,
        player_muted,
        system_volume,
        system_muted,
    })
}

pub async fn set_zone_volume(
    pool: &DbPool,
    zone_id: &str,
    mode: VolumeControlMode,
    volume: f32,
    muted: Option<bool>,
) -> Result<ZoneVolume> {
    ensure_zone_preferences(pool, zone_id).await?;
    let volume = volume.clamp(0.0, 1.0) as f64;
    let muted = muted.map(|value| if value { 1_i64 } else { 0_i64 });
    let now = Utc::now().to_rfc3339();
    match mode {
        VolumeControlMode::Player => {
            sqlx::query(
                r#"
                UPDATE zone_preferences
                SET volume_mode = 'player',
                    volume = ?2,
                    muted = COALESCE(?3, player_muted),
                    player_volume = ?2,
                    player_muted = COALESCE(?3, player_muted),
                    updated_at = ?4
                WHERE zone_id = ?1
                "#,
            )
            .bind(zone_id)
            .bind(volume)
            .bind(muted)
            .bind(now)
            .execute(pool)
            .await?;
        }
        VolumeControlMode::System => {
            sqlx::query(
                r#"
                UPDATE zone_preferences
                SET volume_mode = 'system',
                    volume = ?2,
                    muted = COALESCE(?3, COALESCE(system_muted, 0)),
                    system_volume = ?2,
                    system_muted = COALESCE(?3, COALESCE(system_muted, 0)),
                    updated_at = ?4
                WHERE zone_id = ?1
                "#,
            )
            .bind(zone_id)
            .bind(volume)
            .bind(muted)
            .bind(now)
            .execute(pool)
            .await?;
        }
    }
    zone_volume(pool, zone_id).await
}

pub async fn set_zone_system_volume_state(
    pool: &DbPool,
    zone_id: &str,
    volume: f32,
    muted: bool,
) -> Result<ZoneVolume> {
    ensure_zone_preferences(pool, zone_id).await?;
    sqlx::query(
        r#"
        UPDATE zone_preferences
        SET system_volume = CASE
                WHEN ?3 = 1 AND ?2 <= 0.001 THEN system_volume
                ELSE ?2
            END,
            system_muted = ?3,
            volume = CASE
                WHEN volume_mode != 'system' THEN volume
                WHEN ?3 = 1 AND ?2 <= 0.001 THEN COALESCE(system_volume, volume)
                ELSE ?2
            END,
            muted = CASE WHEN volume_mode = 'system' THEN ?3 ELSE muted END,
            updated_at = ?4
        WHERE zone_id = ?1
        "#,
    )
    .bind(zone_id)
    .bind(volume.clamp(0.0, 1.0) as f64)
    .bind(if muted { 1_i64 } else { 0_i64 })
    .bind(Utc::now().to_rfc3339())
    .execute(pool)
    .await?;
    zone_volume(pool, zone_id).await
}

async fn ensure_playback_queue(pool: &DbPool, zone_id: &str) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT OR IGNORE INTO playback_queues (
            zone_id, revision, mode, current_index, shuffle_seed, created_at, updated_at
        )
        VALUES (?1, 0, 'sequential', NULL, 1, ?2, ?2)
        "#,
    )
    .bind(zone_id)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(())
}

async fn ensure_zone_preferences(pool: &DbPool, zone_id: &str) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT OR IGNORE INTO zone_preferences (
            zone_id, volume, muted, created_at, updated_at
        )
        VALUES (?1, 1.0, 0, ?2, ?2)
        "#,
    )
    .bind(zone_id)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(())
}

async fn playback_queue_shuffle_seed(pool: &DbPool, zone_id: &str) -> Result<i64> {
    ensure_playback_queue(pool, zone_id).await?;
    Ok(
        sqlx::query("SELECT shuffle_seed FROM playback_queues WHERE zone_id = ?1")
            .bind(zone_id)
            .fetch_one(pool)
            .await?
            .try_get("shuffle_seed")?,
    )
}

fn shuffle_key(item_id: u64, seed: u64) -> u64 {
    let mut value = item_id ^ seed.wrapping_mul(0x9E37_79B9_7F4A_7C15);
    value ^= value >> 30;
    value = value.wrapping_mul(0xBF58_476D_1CE4_E5B9);
    value ^= value >> 27;
    value = value.wrapping_mul(0x94D0_49BB_1331_11EB);
    value ^ (value >> 31)
}

fn playback_mode_as_str(mode: &PlaybackMode) -> &'static str {
    match mode {
        PlaybackMode::Single => "single",
        PlaybackMode::RepeatOne => "repeat_one",
        PlaybackMode::Shuffle => "shuffle",
        PlaybackMode::RepeatAll => "repeat_all",
        PlaybackMode::Sequential => "sequential",
    }
}

fn parse_playback_mode(value: &str) -> PlaybackMode {
    match value {
        "single" => PlaybackMode::Single,
        "repeat_one" => PlaybackMode::RepeatOne,
        "shuffle" => PlaybackMode::Shuffle,
        "repeat_all" => PlaybackMode::RepeatAll,
        _ => PlaybackMode::Sequential,
    }
}
