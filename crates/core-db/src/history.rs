use super::*;

pub async fn record_playback_event(
    pool: &DbPool,
    event: PlaybackEventIngest,
) -> Result<PlaybackEvent> {
    let now = Utc::now().to_rfc3339();
    let position_ms = event.position_ms.map(|value| value as i64);
    let id = sqlx::query(
        r#"
        INSERT INTO playback_events (
            zone_id, event_type, track_id, track_title, position_ms,
            related_zone_id, reason, created_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        RETURNING id
        "#,
    )
    .bind(&event.zone_id)
    .bind(&event.event_type)
    .bind(event.track_id)
    .bind(&event.track_title)
    .bind(position_ms)
    .bind(&event.related_zone_id)
    .bind(&event.reason)
    .bind(&now)
    .fetch_one(pool)
    .await?
    .try_get::<i64, _>("id")?;

    get_playback_event(pool, id).await
}

pub async fn start_playback_session(
    pool: &DbPool,
    zone_id: &str,
    track_id: i64,
    track_title: &str,
    start_position_ms: u64,
) -> Result<PlaybackSession> {
    let now = Utc::now().to_rfc3339();
    let id = sqlx::query(
        r#"
        INSERT INTO playback_sessions (
            zone_id, track_id, track_title, started_at, start_position_ms,
            created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?4, ?4)
        RETURNING id
        "#,
    )
    .bind(zone_id)
    .bind(track_id)
    .bind(track_title)
    .bind(&now)
    .bind(start_position_ms as i64)
    .fetch_one(pool)
    .await?
    .try_get::<i64, _>("id")?;

    get_playback_session(pool, id).await
}

pub async fn update_open_playback_session_position(
    pool: &DbPool,
    zone_id: &str,
    position_ms: u64,
) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        UPDATE playback_sessions
        SET played_ms = MAX(?1 - start_position_ms, 0), updated_at = ?2
        WHERE id = (
            SELECT id FROM playback_sessions
            WHERE zone_id = ?3 AND ended_at IS NULL
            ORDER BY started_at DESC
            LIMIT 1
        )
        "#,
    )
    .bind(position_ms as i64)
    .bind(now)
    .bind(zone_id)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn finish_open_playback_session(
    pool: &DbPool,
    zone_id: &str,
    end_position_ms: u64,
    reason: &str,
) -> Result<Option<PlaybackSession>> {
    let Some(id) = open_playback_session_id(pool, zone_id).await? else {
        return Ok(None);
    };
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        UPDATE playback_sessions
        SET ended_at = ?1,
            end_position_ms = ?2,
            end_reason = ?3,
            played_ms = MAX(?2 - start_position_ms, 0),
            updated_at = ?1
        WHERE id = ?4
        "#,
    )
    .bind(&now)
    .bind(end_position_ms as i64)
    .bind(reason)
    .bind(id)
    .execute(pool)
    .await?;

    Ok(Some(get_playback_session(pool, id).await?))
}

pub async fn list_playback_events(
    pool: &DbPool,
    limit: u32,
    offset: u32,
    from: Option<String>,
    to: Option<String>,
) -> Result<Vec<PlaybackEvent>> {
    let rows = sqlx::query(
        r#"
        SELECT id, zone_id, event_type, track_id, track_title, position_ms,
               related_zone_id, reason, created_at
        FROM playback_events
        WHERE (?1 IS NULL OR created_at >= ?1)
          AND (?2 IS NULL OR created_at < ?2)
        ORDER BY created_at DESC, id DESC
        LIMIT ?3 OFFSET ?4
        "#,
    )
    .bind(from)
    .bind(to)
    .bind(limit as i64)
    .bind(offset as i64)
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_playback_event).collect()
}

pub async fn list_playback_sessions(
    pool: &DbPool,
    limit: u32,
    offset: u32,
    from: Option<String>,
    to: Option<String>,
) -> Result<Vec<PlaybackSession>> {
    let rows = sqlx::query(
        r#"
        SELECT id, zone_id, track_id, track_title, started_at, start_position_ms,
               ended_at, end_position_ms, end_reason, played_ms
        FROM playback_sessions
        WHERE (?1 IS NULL OR started_at >= ?1)
          AND (?2 IS NULL OR started_at < ?2)
        ORDER BY started_at DESC, id DESC
        LIMIT ?3 OFFSET ?4
        "#,
    )
    .bind(from)
    .bind(to)
    .bind(limit as i64)
    .bind(offset as i64)
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_playback_session).collect()
}

pub async fn playback_stats(
    pool: &DbPool,
    from: Option<String>,
    to: Option<String>,
    top_limit: u32,
) -> Result<PlaybackStats> {
    let total_events = sqlx::query(
        r#"
        SELECT COUNT(*) AS count
        FROM playback_events
        WHERE (?1 IS NULL OR created_at >= ?1)
          AND (?2 IS NULL OR created_at < ?2)
        "#,
    )
    .bind(from.as_deref())
    .bind(to.as_deref())
    .fetch_one(pool)
    .await?
    .try_get::<i64, _>("count")?;

    let session_row = sqlx::query(
        r#"
        SELECT
            COUNT(*) AS total_sessions,
            COALESCE(SUM(played_ms), 0) AS total_played_ms,
            SUM(CASE WHEN end_reason = 'completed' THEN 1 ELSE 0 END) AS completed_sessions,
            SUM(CASE WHEN ended_at IS NOT NULL AND end_reason != 'completed' THEN 1 ELSE 0 END) AS interrupted_sessions
        FROM playback_sessions
        WHERE (?1 IS NULL OR started_at >= ?1)
          AND (?2 IS NULL OR started_at < ?2)
        "#,
    )
    .bind(from.as_deref())
    .bind(to.as_deref())
    .fetch_one(pool)
    .await?;

    let top_rows = sqlx::query(
        r#"
        SELECT
            s.track_id,
            COALESCE(t.title, s.track_title) AS title,
            COALESCE(GROUP_CONCAT(DISTINCT ar.name), NULL) AS artist_display,
            al.title AS album_title,
            COUNT(*) AS play_count,
            COALESCE(SUM(s.played_ms), 0) AS total_played_ms,
            MAX(s.started_at) AS last_played_at
        FROM playback_sessions s
        LEFT JOIN tracks t ON t.id = s.track_id
        LEFT JOIN albums al ON al.id = t.album_id
        LEFT JOIN track_artists ta ON ta.track_id = t.id AND ta.role = 'primary'
        LEFT JOIN artists ar ON ar.id = ta.artist_id
        WHERE (?1 IS NULL OR s.started_at >= ?1)
          AND (?2 IS NULL OR s.started_at < ?2)
        GROUP BY s.track_id
        ORDER BY total_played_ms DESC, play_count DESC
        LIMIT ?3
        "#,
    )
    .bind(from.as_deref())
    .bind(to.as_deref())
    .bind(top_limit.clamp(1, 100) as i64)
    .fetch_all(pool)
    .await?;

    Ok(PlaybackStats {
        total_events,
        total_sessions: session_row.try_get("total_sessions")?,
        total_played_ms: session_row.try_get::<i64, _>("total_played_ms")? as u64,
        completed_sessions: session_row
            .try_get::<Option<i64>, _>("completed_sessions")?
            .unwrap_or(0),
        interrupted_sessions: session_row
            .try_get::<Option<i64>, _>("interrupted_sessions")?
            .unwrap_or(0),
        top_tracks: top_rows
            .into_iter()
            .map(row_to_track_playback_stat)
            .collect::<Result<_>>()?,
    })
}

pub async fn list_zones(pool: &DbPool) -> Result<Vec<protocol::ZoneSummary>> {
    let rows = sqlx::query("SELECT id, name, output_id, state, volume FROM zones ORDER BY name")
        .fetch_all(pool)
        .await?;
    rows.into_iter()
        .map(|row| {
            let state = match row.try_get::<String, _>("state")?.as_str() {
                "playing" => protocol::PlaybackTransportState::Playing,
                "paused" => protocol::PlaybackTransportState::Paused,
                _ => protocol::PlaybackTransportState::Stopped,
            };
            Ok(protocol::ZoneSummary {
                id: row.try_get("id")?,
                name: row.try_get("name")?,
                system_name: row.try_get("name")?,
                alias: None,
                output_id: row.try_get("output_id")?,
                state,
                volume: row.try_get::<f64, _>("volume")? as f32,
                muted: false,
                volume_mode: VolumeControlMode::Player,
                player_volume: row.try_get::<f64, _>("volume")? as f32,
                player_muted: false,
                system_volume: None,
                system_muted: None,
                system_volume_supported: false,
                system_volume_readable: false,
                system_volume_writable: false,
                system_volume_steps: None,
                track_id: None,
                track_title: None,
                position_ms: 0,
                command_sequence: None,
                origin_client_id: None,
                intent_id: None,
                is_online: true,
                is_remote: false,
                node_id: Some("core".to_string()),
                node_name: Some("Core local".to_string()),
            })
        })
        .collect()
}

pub async fn list_zone_aliases(pool: &DbPool) -> Result<HashMap<String, String>> {
    let rows = sqlx::query("SELECT zone_id, alias FROM zone_aliases")
        .fetch_all(pool)
        .await?;

    rows.into_iter()
        .map(|row| Ok((row.try_get("zone_id")?, row.try_get("alias")?)))
        .collect()
}

pub async fn set_zone_alias(
    pool: &DbPool,
    zone_id: &str,
    alias: Option<&str>,
) -> Result<Option<String>> {
    let cleaned = alias
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned);
    let now = Utc::now().to_rfc3339();

    if let Some(alias) = cleaned {
        sqlx::query(
            r#"
            INSERT INTO zone_aliases (zone_id, alias, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?3)
            ON CONFLICT(zone_id) DO UPDATE SET
                alias = excluded.alias,
                updated_at = excluded.updated_at
            "#,
        )
        .bind(zone_id)
        .bind(&alias)
        .bind(&now)
        .execute(pool)
        .await?;
        Ok(Some(alias))
    } else {
        sqlx::query("DELETE FROM zone_aliases WHERE zone_id = ?1")
            .bind(zone_id)
            .execute(pool)
            .await?;
        Ok(None)
    }
}

pub async fn set_zone_state(pool: &DbPool, zone_id: &str, state: &str) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    sqlx::query("UPDATE zones SET state = ?1, updated_at = ?2 WHERE id = ?3")
        .bind(state)
        .bind(now)
        .bind(zone_id)
        .execute(pool)
        .await?;
    Ok(())
}
