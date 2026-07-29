use super::*;

pub async fn apply_client_mutations(
    pool: &DbPool,
    request: &ClientMutationBatchRequest,
) -> Result<ClientMutationBatchResult> {
    let device_id = request.device_id.trim();
    let device_name = request.device_name.trim();
    if device_id.is_empty() || device_id.len() > 200 {
        bail!("device_id must contain between 1 and 200 characters");
    }
    if device_name.is_empty() || device_name.len() > 300 {
        bail!("device_name must contain between 1 and 300 characters");
    }
    if request.mutations.len() > 500 {
        bail!("a client mutation batch cannot exceed 500 operations");
    }

    let now = Utc::now().to_rfc3339();
    let mut tx = pool.begin().await?;
    sqlx::query(
        r#"
        INSERT INTO devices (
            id, name, platform, token_hash, created_at, last_seen_at
        )
        VALUES (?1, ?2, ?3, 'client-mutation-sync', ?4, ?4)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            platform = COALESCE(excluded.platform, devices.platform),
            last_seen_at = excluded.last_seen_at
        "#,
    )
    .bind(device_id)
    .bind(device_name)
    .bind(&request.platform)
    .bind(&now)
    .execute(&mut *tx)
    .await?;

    let mut applied_ids = Vec::new();
    let mut duplicate_ids = Vec::new();
    for mutation in &request.mutations {
        let mutation_id = mutation.id.trim();
        if mutation_id.is_empty() || mutation_id.len() > 200 {
            bail!("mutation id must contain between 1 and 200 characters");
        }
        let duplicate: Option<i64> = sqlx::query_scalar(
            r#"
            SELECT 1
            FROM client_mutation_receipts
            WHERE device_id = ?1 AND mutation_id = ?2
            "#,
        )
        .bind(device_id)
        .bind(mutation_id)
        .fetch_optional(&mut *tx)
        .await?;
        if duplicate.is_some() {
            duplicate_ids.push(mutation_id.to_string());
            continue;
        }

        let track_title: String = sqlx::query_scalar("SELECT title FROM tracks WHERE id = ?1")
            .bind(mutation.track_id)
            .fetch_one(&mut *tx)
            .await
            .with_context(|| {
                format!(
                    "offline mutation {} references unknown track {}",
                    mutation_id, mutation.track_id
                )
            })?;
        let occurred_at = mutation.occurred_at.to_rfc3339();
        match mutation.kind.as_str() {
            "favorite" => {
                let favorite = mutation
                    .payload
                    .get("is_favorite")
                    .and_then(Value::as_bool)
                    .context("favorite mutation requires payload.is_favorite")?;
                sqlx::query(
                    r#"
                    INSERT INTO user_track_state (
                        track_id, is_favorite, favorite_updated_at,
                        created_at, updated_at
                    )
                    VALUES (?1, ?2, ?3, ?3, ?3)
                    ON CONFLICT(track_id) DO UPDATE SET
                        is_favorite = excluded.is_favorite,
                        favorite_updated_at = excluded.favorite_updated_at,
                        updated_at = excluded.updated_at
                    WHERE user_track_state.favorite_updated_at IS NULL
                       OR user_track_state.favorite_updated_at <= excluded.favorite_updated_at
                    "#,
                )
                .bind(mutation.track_id)
                .bind(if favorite { 1_i64 } else { 0_i64 })
                .bind(&occurred_at)
                .execute(&mut *tx)
                .await?;
            }
            "playback" => {
                let started_at = mutation
                    .payload
                    .get("started_at")
                    .and_then(Value::as_str)
                    .unwrap_or(&occurred_at);
                let ended_at = mutation
                    .payload
                    .get("ended_at")
                    .and_then(Value::as_str)
                    .unwrap_or(&occurred_at);
                DateTime::parse_from_rfc3339(started_at)
                    .context("playback mutation started_at must be RFC 3339")?;
                DateTime::parse_from_rfc3339(ended_at)
                    .context("playback mutation ended_at must be RFC 3339")?;
                let start_position_ms = mutation
                    .payload
                    .get("start_position_ms")
                    .and_then(Value::as_i64)
                    .unwrap_or(0)
                    .max(0);
                let end_position_ms = mutation
                    .payload
                    .get("end_position_ms")
                    .and_then(Value::as_i64)
                    .unwrap_or(start_position_ms)
                    .max(0);
                let reason = mutation
                    .payload
                    .get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("offline");
                if reason.len() > 100 {
                    bail!("playback mutation reason cannot exceed 100 characters");
                }
                let zone_id = format!("offline:{device_id}");
                sqlx::query(
                    r#"
                    INSERT INTO playback_sessions (
                        zone_id, track_id, track_title, started_at,
                        start_position_ms, ended_at, end_position_ms,
                        end_reason, played_ms, created_at, updated_at
                    )
                    VALUES (
                        ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8,
                        MAX(?7 - ?5, 0), ?4, ?6
                    )
                    "#,
                )
                .bind(&zone_id)
                .bind(mutation.track_id)
                .bind(&track_title)
                .bind(started_at)
                .bind(start_position_ms)
                .bind(ended_at)
                .bind(end_position_ms)
                .bind(reason)
                .execute(&mut *tx)
                .await?;
                sqlx::query(
                    r#"
                    INSERT INTO playback_events (
                        zone_id, event_type, track_id, track_title,
                        position_ms, reason, created_at
                    )
                    VALUES (?1, 'play_start', ?2, ?3, ?4, 'offline', ?5)
                    "#,
                )
                .bind(&zone_id)
                .bind(mutation.track_id)
                .bind(&track_title)
                .bind(start_position_ms)
                .bind(started_at)
                .execute(&mut *tx)
                .await?;
                sqlx::query(
                    r#"
                    INSERT INTO playback_events (
                        zone_id, event_type, track_id, track_title,
                        position_ms, reason, created_at
                    )
                    VALUES (?1, 'stop', ?2, ?3, ?4, ?5, ?6)
                    "#,
                )
                .bind(&zone_id)
                .bind(mutation.track_id)
                .bind(&track_title)
                .bind(end_position_ms)
                .bind(reason)
                .bind(ended_at)
                .execute(&mut *tx)
                .await?;
            }
            kind => bail!("unsupported client mutation kind: {kind}"),
        }
        sqlx::query(
            r#"
            INSERT INTO client_mutation_receipts (
                device_id, mutation_id, mutation_kind, occurred_at, applied_at
            )
            VALUES (?1, ?2, ?3, ?4, ?5)
            "#,
        )
        .bind(device_id)
        .bind(mutation_id)
        .bind(&mutation.kind)
        .bind(&occurred_at)
        .bind(&now)
        .execute(&mut *tx)
        .await?;
        applied_ids.push(mutation_id.to_string());
    }
    tx.commit().await?;
    Ok(ClientMutationBatchResult {
        applied_ids,
        duplicate_ids,
    })
}
