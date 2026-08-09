use super::*;
use playback::session_v3::{next_item, previous_item, QueueAdvanceV3};
use protocol::{
    PlaybackCommandAckV3, PlaybackCommandStatusV3, PlaybackRepeatModeV3, PlaybackSessionActionV3,
    PlaybackSessionCommandV3, PlaybackSessionEventV3, PlaybackSessionModeV3,
    PlaybackSessionResumeRequestV3, PlaybackSessionResumeV3, PlaybackSessionSnapshotV3,
};

pub(crate) async fn get_playback_session_v3(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
) -> ApiResult<PlaybackSessionSnapshotV3> {
    Ok(Json(playback_session_snapshot_v3(&state, &zone_id).await?))
}

pub(crate) async fn command_playback_session_v3(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    Json(command): Json<PlaybackSessionCommandV3>,
) -> ApiResult<PlaybackCommandAckV3> {
    let gate = state.playback_control_gate(&zone_id).await;
    let _guard = gate.lock().await;

    if let Some(receipt) = core_db::playback_command_receipt(
        state.pool(),
        &command.origin_device_id,
        &command.command_id.to_string(),
    )
    .await?
    {
        if receipt.zone_id != zone_id || receipt.action != "playback_v3" {
            return Ok(Json(
                rejected_ack_v3(&state, &zone_id, command.command_id, "command_id_reused").await?,
            ));
        }
        let mut ack: PlaybackCommandAckV3 =
            serde_json::from_str(&receipt.response_json).map_err(anyhow::Error::from)?;
        if matches!(
            ack.status,
            PlaybackCommandStatusV3::Applied | PlaybackCommandStatusV3::Duplicate
        ) {
            ack.status = PlaybackCommandStatusV3::Duplicate;
        }
        return Ok(Json(ack));
    }

    let current = playback_session_snapshot_v3(&state, &zone_id).await?;
    if command.session_id != current.session_id {
        let ack = conflict_ack_v3(
            command.command_id,
            &current,
            PlaybackCommandStatusV3::Rejected,
            "session_mismatch",
        );
        record_ack_v3(&state, &zone_id, &command, &ack).await?;
        return Ok(Json(ack));
    }
    if command.epoch != current.epoch {
        let ack = conflict_ack_v3(
            command.command_id,
            &current,
            PlaybackCommandStatusV3::Conflict,
            "epoch_conflict",
        );
        record_ack_v3(&state, &zone_id, &command, &ack).await?;
        return Ok(Json(ack));
    }
    if command.expected_revision != current.revision {
        let ack = conflict_ack_v3(
            command.command_id,
            &current,
            PlaybackCommandStatusV3::Conflict,
            "revision_conflict",
        );
        record_ack_v3(&state, &zone_id, &command, &ack).await?;
        return Ok(Json(ack));
    }

    let context = PlaybackCommandContext {
        origin_client_id: Some(command.origin_device_id.clone()),
        intent_id: Some(command.command_id.to_string()),
    };
    if let Err(error) =
        apply_session_action_v3(&state, &zone_id, &current, &context, command.action.clone()).await
    {
        warn!(%error, zone_id, command_id = %command.command_id, "rejected v3 playback command");
        let snapshot = playback_session_snapshot_v3(&state, &zone_id).await?;
        let ack = conflict_ack_v3(
            command.command_id,
            &snapshot,
            PlaybackCommandStatusV3::Rejected,
            "command_rejected",
        );
        record_ack_v3(&state, &zone_id, &command, &ack).await?;
        return Ok(Json(ack));
    }

    core_db::advance_playback_session_v3(
        state.pool(),
        &zone_id,
        command.command_id,
        state.inner.event_cursor.load(Ordering::SeqCst),
    )
    .await?;
    let applied = playback_session_snapshot_v3(&state, &zone_id).await?;
    let event_cursor = state.emit_with_cursor(
        "playback.session_v3.changed",
        json!({
            "session_id": applied.session_id,
            "zone_id": zone_id,
            "epoch": applied.epoch,
            "revision": applied.revision,
            "command_id": command.command_id,
        }),
    );
    core_db::update_playback_session_cursor_v3(state.pool(), &zone_id, event_cursor).await?;
    let snapshot = playback_session_snapshot_v3(&state, &zone_id).await?;
    let ack = PlaybackCommandAckV3 {
        command_id: command.command_id,
        session_id: snapshot.session_id,
        epoch: snapshot.epoch,
        status: PlaybackCommandStatusV3::Applied,
        applied_revision: snapshot.revision,
        error_code: None,
        snapshot: Some(snapshot),
    };
    record_ack_v3(&state, &zone_id, &command, &ack).await?;
    Ok(Json(ack))
}

pub(crate) async fn resume_playback_session_v3(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    Json(request): Json<PlaybackSessionResumeRequestV3>,
) -> ApiResult<PlaybackSessionResumeV3> {
    let snapshot = playback_session_snapshot_v3(&state, &zone_id).await?;
    if request.session_id != snapshot.session_id
        || request.known_epoch != snapshot.epoch
        || request.known_revision > snapshot.revision
    {
        return Ok(Json(PlaybackSessionResumeV3 {
            snapshot,
            events: Vec::new(),
            has_more: false,
        }));
    }

    let page = core_db::replay_events(state.pool(), request.after_cursor, 500).await?;
    if page.requires_snapshot {
        return Ok(Json(PlaybackSessionResumeV3 {
            snapshot,
            events: Vec::new(),
            has_more: false,
        }));
    }
    let events = page
        .events
        .into_iter()
        .filter(|event| {
            event.event_type == "playback.session_v3.changed"
                && event
                    .payload
                    .get("zone_id")
                    .and_then(|value| value.as_str())
                    == Some(zone_id.as_str())
        })
        .filter_map(|event| event_envelope_to_session_v3(event).transpose())
        .collect::<Result<Vec<_>>>()?;
    Ok(Json(PlaybackSessionResumeV3 {
        snapshot,
        events,
        has_more: page.has_more,
    }))
}

async fn playback_session_snapshot_v3(
    state: &AppState,
    zone_id: &str,
) -> Result<PlaybackSessionSnapshotV3> {
    let owner_device_id = owner_device_id_for_zone(zone_id);
    let cursor = state.inner.event_cursor.load(Ordering::SeqCst);
    core_db::ensure_playback_session_v3(state.pool(), zone_id, &owner_device_id, cursor).await?;
    let queue = core_db::playback_queue_state_v3(state.pool(), zone_id).await?;
    let meta = core_db::synchronize_playback_session_revision_v3(state.pool(), zone_id).await?;
    let playback = playback_state_for_zone(state, zone_id)
        .await
        .unwrap_or_else(|_| PlaybackState {
            zone_id: zone_id.to_string(),
            state: PlaybackTransportState::Stopped,
            track_id: None,
            track_title: None,
            position_ms: 0,
            queue_revision: 0,
            command_sequence: None,
            origin_client_id: None,
            intent_id: None,
        });
    Ok(PlaybackSessionSnapshotV3 {
        session_id: meta.session_id,
        zone_id: meta.zone_id,
        owner_device_id: meta.owner_device_id,
        epoch: meta.epoch,
        revision: meta.revision,
        event_cursor: meta.event_cursor.max(cursor),
        transport: playback.state,
        current_item_id: queue.current_item_id,
        position_ms: playback.position_ms,
        mode: meta.mode,
        shuffle_seed: queue.shuffle_seed,
        queue: queue.items,
        last_command_id: meta.last_command_id,
        updated_at: meta.updated_at,
    })
}

async fn apply_session_action_v3(
    state: &AppState,
    zone_id: &str,
    snapshot: &PlaybackSessionSnapshotV3,
    context: &PlaybackCommandContext,
    action: PlaybackSessionActionV3,
) -> Result<()> {
    match action {
        PlaybackSessionActionV3::Play {
            item_id,
            position_ms,
        } => {
            if let Some(item_id) = item_id {
                let track_id =
                    core_db::set_playback_queue_current_item_v3(state.pool(), zone_id, item_id)
                        .await?;
                emit_legacy_queue_changed(state, zone_id).await?;
                play_track_on_zone_preserving_queue(state, zone_id, track_id, position_ms, context)
                    .await?;
            } else {
                resume_zone_internal(state, zone_id, context).await?;
            }
        }
        PlaybackSessionActionV3::Pause => {
            pause_zone_internal(state, zone_id, context).await?;
        }
        PlaybackSessionActionV3::Stop => {
            stop_zone_internal(state, zone_id, context).await?;
        }
        PlaybackSessionActionV3::Seek { position_ms } => {
            seek_zone_internal(state, zone_id, position_ms, context).await?;
        }
        PlaybackSessionActionV3::Next { automatic } => {
            apply_queue_advance_v3(state, zone_id, context, next_item(snapshot, automatic)).await?;
        }
        PlaybackSessionActionV3::Previous => {
            apply_queue_advance_v3(state, zone_id, context, previous_item(snapshot)).await?;
        }
        PlaybackSessionActionV3::ReplaceQueue {
            items,
            start_item_id,
        } => {
            core_db::replace_playback_queue_v3(state.pool(), zone_id, &items, start_item_id)
                .await?;
            emit_legacy_queue_changed(state, zone_id).await?;
        }
        PlaybackSessionActionV3::ReplaceQueueAndPlay {
            items,
            start_item_id,
            position_ms,
        } => {
            let track_id = items
                .iter()
                .find(|item| item.item_id == start_item_id)
                .map(|item| item.track_id)
                .ok_or_else(|| {
                    anyhow::anyhow!("start queue item {start_item_id} does not exist")
                })?;
            core_db::replace_playback_queue_v3(state.pool(), zone_id, &items, Some(start_item_id))
                .await?;
            emit_legacy_queue_changed(state, zone_id).await?;
            play_track_on_zone_preserving_queue(state, zone_id, track_id, position_ms, context)
                .await?;
        }
        PlaybackSessionActionV3::AddQueueItems {
            items,
            before_item_id,
        } => {
            let current = core_db::playback_queue_state_v3(state.pool(), zone_id).await?;
            let mut merged = current.items;
            let position = before_item_id
                .and_then(|item_id| merged.iter().position(|item| item.item_id == item_id))
                .unwrap_or(merged.len());
            merged.splice(position..position, items);
            core_db::replace_playback_queue_v3(
                state.pool(),
                zone_id,
                &merged,
                current.current_item_id,
            )
            .await?;
            emit_legacy_queue_changed(state, zone_id).await?;
        }
        PlaybackSessionActionV3::MoveQueueItem {
            item_id,
            before_item_id,
        } => {
            let current = core_db::playback_queue_state_v3(state.pool(), zone_id).await?;
            let mut items = current.items;
            let from = items
                .iter()
                .position(|item| item.item_id == item_id)
                .ok_or_else(|| anyhow::anyhow!("queue item {item_id} does not exist"))?;
            let item = items.remove(from);
            let target = before_item_id
                .and_then(|before| items.iter().position(|item| item.item_id == before))
                .unwrap_or(items.len());
            items.insert(target, item);
            core_db::replace_playback_queue_v3(
                state.pool(),
                zone_id,
                &items,
                current.current_item_id,
            )
            .await?;
            emit_legacy_queue_changed(state, zone_id).await?;
        }
        PlaybackSessionActionV3::RemoveQueueItem { item_id } => {
            let current = core_db::playback_queue_state_v3(state.pool(), zone_id).await?;
            let mut items = current.items;
            let index = items
                .iter()
                .position(|item| item.item_id == item_id)
                .ok_or_else(|| anyhow::anyhow!("queue item {item_id} does not exist"))?;
            items.remove(index);
            let next_current = if current.current_item_id == Some(item_id) {
                items
                    .get(index)
                    .or_else(|| index.checked_sub(1).and_then(|index| items.get(index)))
                    .map(|item| item.item_id)
            } else {
                current.current_item_id
            };
            core_db::replace_playback_queue_v3(state.pool(), zone_id, &items, next_current).await?;
            emit_legacy_queue_changed(state, zone_id).await?;
        }
        PlaybackSessionActionV3::SetMode { mode } => {
            core_db::update_playback_session_mode_v3(state.pool(), zone_id, mode).await?;
            let queue =
                core_db::set_playback_mode(state.pool(), zone_id, legacy_mode(mode)).await?;
            state.emit("playback.queue_changed", &queue);
        }
    }
    Ok(())
}

async fn apply_queue_advance_v3(
    state: &AppState,
    zone_id: &str,
    context: &PlaybackCommandContext,
    advance: QueueAdvanceV3,
) -> Result<()> {
    match advance {
        QueueAdvanceV3::Select(item_id) => {
            let track_id =
                core_db::set_playback_queue_current_item_v3(state.pool(), zone_id, item_id).await?;
            emit_legacy_queue_changed(state, zone_id).await?;
            play_track_on_zone_preserving_queue(state, zone_id, track_id, 0, context).await?;
        }
        QueueAdvanceV3::Stop => {
            stop_zone_internal_with_reason(state, zone_id, "queue_completed", None, context)
                .await?;
        }
    }
    Ok(())
}

async fn emit_legacy_queue_changed(state: &AppState, zone_id: &str) -> Result<()> {
    let queue = core_db::playback_queue(state.pool(), zone_id).await?;
    state.emit("playback.queue_changed", &queue);
    Ok(())
}

async fn rejected_ack_v3(
    state: &AppState,
    zone_id: &str,
    command_id: Uuid,
    error_code: &str,
) -> Result<PlaybackCommandAckV3> {
    let snapshot = playback_session_snapshot_v3(state, zone_id).await?;
    Ok(conflict_ack_v3(
        command_id,
        &snapshot,
        PlaybackCommandStatusV3::Rejected,
        error_code,
    ))
}

fn conflict_ack_v3(
    command_id: Uuid,
    snapshot: &PlaybackSessionSnapshotV3,
    status: PlaybackCommandStatusV3,
    error_code: &str,
) -> PlaybackCommandAckV3 {
    PlaybackCommandAckV3 {
        command_id,
        session_id: snapshot.session_id,
        epoch: snapshot.epoch,
        status,
        applied_revision: snapshot.revision,
        error_code: Some(error_code.to_string()),
        snapshot: Some(snapshot.clone()),
    }
}

async fn record_ack_v3(
    state: &AppState,
    zone_id: &str,
    command: &PlaybackSessionCommandV3,
    ack: &PlaybackCommandAckV3,
) -> Result<()> {
    core_db::record_playback_command_receipt(
        state.pool(),
        &command.origin_device_id,
        &command.command_id.to_string(),
        zone_id,
        "playback_v3",
        &serde_json::to_string(ack)?,
    )
    .await
}

fn owner_device_id_for_zone(zone_id: &str) -> String {
    zone_id
        .strip_prefix("renderer:")
        .and_then(|value| value.split_once(':'))
        .map(|(client_id, _)| client_id.to_string())
        .unwrap_or_else(|| "core".to_string())
}

fn legacy_mode(mode: PlaybackSessionModeV3) -> PlaybackMode {
    if mode.stop_after_current {
        PlaybackMode::Single
    } else if mode.repeat == PlaybackRepeatModeV3::One {
        PlaybackMode::RepeatOne
    } else if mode.shuffle {
        PlaybackMode::Shuffle
    } else if mode.repeat == PlaybackRepeatModeV3::All {
        PlaybackMode::RepeatAll
    } else {
        PlaybackMode::Sequential
    }
}

fn event_envelope_to_session_v3(event: EventEnvelope) -> Result<Option<PlaybackSessionEventV3>> {
    let Some(cursor) = event.cursor else {
        return Ok(None);
    };
    let session_id = event
        .payload
        .get("session_id")
        .and_then(|value| value.as_str())
        .map(Uuid::parse_str)
        .transpose()?
        .ok_or_else(|| anyhow::anyhow!("v3 playback event is missing session_id"))?;
    let epoch = event
        .payload
        .get("epoch")
        .and_then(|value| value.as_u64())
        .ok_or_else(|| anyhow::anyhow!("v3 playback event is missing epoch"))?;
    let revision = event
        .payload
        .get("revision")
        .and_then(|value| value.as_u64())
        .ok_or_else(|| anyhow::anyhow!("v3 playback event is missing revision"))?;
    Ok(Some(PlaybackSessionEventV3 {
        cursor,
        event_id: event.id,
        session_id,
        epoch,
        revision,
        event_type: event.event_type,
        payload: event.payload,
        created_at: event.time,
    }))
}
