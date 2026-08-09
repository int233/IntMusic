use super::*;

pub(crate) async fn list_outputs(
    State(state): State<AppState>,
) -> ApiResult<Vec<protocol::OutputDevice>> {
    let core_name = core_display_name(&state.config());
    let mut outputs = output_cpal::list_output_devices()?;
    for output in &mut outputs {
        output.node_name = Some(core_name.clone());
    }
    outputs.extend(state.inner.renderers.list_outputs().await);
    Ok(Json(outputs))
}

pub(crate) async fn list_renderers(
    State(state): State<AppState>,
) -> ApiResult<Vec<protocol::RegisteredRenderer>> {
    Ok(Json(state.inner.renderers.list_renderers().await))
}

pub(crate) async fn register_renderer(
    State(state): State<AppState>,
    Json(payload): Json<RendererRegistration>,
) -> ApiResult<protocol::RegisteredRenderer> {
    let request_playback_sync = payload.request_playback_sync;
    let reported_system_volumes = payload
        .outputs
        .iter()
        .filter_map(|output| {
            Some((
                renderers::remote_output_id(&payload.client_id, &output.id),
                output.system_volume?,
                output.system_muted.unwrap_or(false),
            ))
        })
        .collect::<Vec<_>>();
    let (renderer, reset_states) = state.inner.renderers.register(payload).await;
    for (zone_id, volume, muted) in reported_system_volumes {
        let current =
            core_db::set_zone_system_volume_state(state.pool(), &zone_id, volume, muted).await?;
        state.emit("zone.volume_changed", &current);
    }
    for (previous, current) in reset_states {
        record_playback_finish(
            &state,
            &previous,
            "renderer_restarted",
            "renderer_reset",
            None,
        )
        .await;
        state.emit("playback.state_changed", &current);
    }
    state.emit("renderer.registered", &renderer);
    if request_playback_sync {
        for output in &renderer.outputs {
            let Some(playback) = state.inner.renderers.state_for_output(&output.id).await else {
                continue;
            };
            let (action, stream_path) = match playback.state {
                PlaybackTransportState::Playing => (
                    "play",
                    playback
                        .track_id
                        .map(|track_id| format!("/tracks/{track_id}/stream")),
                ),
                PlaybackTransportState::Paused => ("pause", None),
                PlaybackTransportState::Stopped => ("stop", None),
            };
            let (renderer_id, command) = create_renderer_command(
                &state,
                RendererCommandRequest {
                    zone_id: &output.id,
                    action,
                    track_id: playback.track_id,
                    track_title: playback.track_title.clone(),
                    stream_path,
                    position_ms: Some(playback.position_ms),
                    volume: None,
                    muted: None,
                    context: &PlaybackCommandContext::default(),
                    expires_after_ms: TRANSPORT_COMMAND_TTL_MS,
                },
            )
            .await?;
            state.emit_renderer_command(&renderer_id, &command);
            let volume = core_db::zone_volume(state.pool(), &output.id).await?;
            if volume.mode == VolumeControlMode::Player || output.system_volume_writable {
                apply_zone_volume(&state, &volume, &PlaybackCommandContext::default()).await?;
            }
        }
    }
    Ok(Json(renderer))
}

pub(crate) async fn report_renderer_state(
    State(state): State<AppState>,
    Path(client_id): Path<String>,
    Json(payload): Json<RendererStateReport>,
) -> ApiResult<PlaybackState> {
    let output_id = if payload.output_id.starts_with("renderer:") {
        payload.output_id.clone()
    } else {
        renderers::remote_output_id(&client_id, &payload.output_id)
    };
    let previous = state.inner.renderers.state_for_output(&output_id).await;
    let playback = state
        .inner
        .renderers
        .report_state(&client_id, payload)
        .await?;
    let transport_changed = previous.as_ref().is_none_or(|previous| {
        previous.state != playback.state
            || previous.track_id != playback.track_id
            || previous.command_sequence != playback.command_sequence
    });
    let position_changed = previous
        .as_ref()
        .is_none_or(|previous| previous.position_ms.abs_diff(playback.position_ms) >= 4_000);
    let completed = previous.as_ref().is_some_and(|previous| {
        previous.track_id.is_some()
            && previous.state == PlaybackTransportState::Playing
            && playback.state == PlaybackTransportState::Stopped
            && transport_changed
    });
    if transport_changed || position_changed {
        record_renderer_state_transition(&state, previous, &playback).await;
        state.emit(
            if transport_changed {
                "playback.state_changed"
            } else {
                "playback.position"
            },
            &playback,
        );
    }
    if completed {
        if let Some(track_id) =
            step_playback_queue_and_emit(&state, &output_id, false, true).await?
        {
            return Ok(Json(
                play_track_on_zone(
                    &state,
                    &output_id,
                    track_id,
                    0,
                    &PlaybackCommandContext::default(),
                )
                .await?,
            ));
        }
    }
    Ok(Json(playback))
}

pub(crate) async fn report_renderer_volume_state(
    State(state): State<AppState>,
    Path(client_id): Path<String>,
    Json(payload): Json<RendererVolumeStateReport>,
) -> ApiResult<ZoneVolume> {
    state
        .inner
        .renderers
        .update_system_volume_capability(
            &client_id,
            &payload.output_id,
            payload.supported,
            payload.readable,
            payload.writable,
            payload.steps,
        )
        .await?;
    let zone_id = if payload.output_id.starts_with("renderer:") {
        payload.output_id
    } else {
        renderers::remote_output_id(&client_id, &payload.output_id)
    };
    let volume = core_db::set_zone_system_volume_state(
        state.pool(),
        &zone_id,
        payload.volume,
        payload.muted,
    )
    .await?;
    state.emit("zone.volume_changed", &volume);
    Ok(Json(volume))
}

pub(crate) async fn list_zones(
    State(state): State<AppState>,
) -> ApiResult<Vec<protocol::ZoneSummary>> {
    let core_name = core_display_name(&state.config());
    let mut zones = core_db::list_zones(state.pool()).await?;
    for zone in &mut zones {
        zone.node_name = Some(core_name.clone());
        if zone.id == "local" {
            zone.system_name = core_name.clone();
            zone.name = core_name.clone();
        }
        let playback = state.inner.playback.state_for_zone(&zone.id).await;
        apply_playback_to_zone(zone, playback);
    }

    for mut output in output_cpal::list_output_devices()? {
        output.node_name = Some(core_name.clone());
        let zone_id = output.id.clone();
        let playback = state.inner.playback.state_for_zone(&zone_id).await;
        let system_name = format!(
            "{} - {}",
            output
                .node_name
                .clone()
                .unwrap_or_else(|| core_name.clone()),
            output.name
        );
        let mut zone = protocol::ZoneSummary {
            id: zone_id.clone(),
            name: system_name.clone(),
            system_name,
            alias: None,
            output_id: Some(zone_id),
            state: playback.state,
            volume: 1.0,
            muted: false,
            volume_mode: protocol::VolumeControlMode::Player,
            player_volume: 1.0,
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
            is_online: output.is_online,
            is_remote: output.is_remote,
            node_id: output.node_id,
            node_name: output.node_name,
        };
        apply_playback_to_zone(&mut zone, playback);
        zones.push(zone);
    }
    zones.extend(state.inner.renderers.list_zones().await);
    apply_zone_aliases(&state, &mut zones).await?;
    apply_zone_preferences(&state, &mut zones).await?;
    Ok(Json(zones))
}

pub(crate) async fn update_zone_alias(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    Json(payload): Json<ZoneAliasUpdate>,
) -> ApiResult<serde_json::Value> {
    let alias = core_db::set_zone_alias(state.pool(), &zone_id, payload.alias.as_deref()).await?;
    state.emit(
        "zone.alias_updated",
        json!({
            "zone_id": zone_id,
            "alias": alias,
        }),
    );
    Ok(Json(json!({ "alias": alias })))
}

pub(crate) async fn apply_zone_aliases(
    state: &AppState,
    zones: &mut [protocol::ZoneSummary],
) -> Result<()> {
    let aliases = core_db::list_zone_aliases(state.pool()).await?;
    for zone in zones {
        if let Some(alias) = aliases.get(&zone.id) {
            zone.alias = Some(alias.clone());
            zone.name = alias.clone();
        }
    }
    Ok(())
}

pub(crate) async fn apply_zone_preferences(
    state: &AppState,
    zones: &mut [protocol::ZoneSummary],
) -> Result<()> {
    for zone in zones {
        let preference = core_db::zone_volume(state.pool(), &zone.id).await?;
        zone.volume = preference.volume;
        zone.muted = preference.muted;
        zone.volume_mode = preference.mode;
        zone.player_volume = preference.player_volume;
        zone.player_muted = preference.player_muted;
        zone.system_volume = preference.system_volume;
        zone.system_muted = preference.system_muted;
    }
    Ok(())
}

pub(crate) fn apply_playback_to_zone(zone: &mut protocol::ZoneSummary, playback: PlaybackState) {
    zone.state = playback.state;
    zone.track_id = playback.track_id;
    zone.track_title = playback.track_title;
    zone.position_ms = playback.position_ms;
    zone.command_sequence = playback.command_sequence;
    zone.origin_client_id = playback.origin_client_id;
    zone.intent_id = playback.intent_id;
}

pub(crate) async fn play_zone(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    payload: Option<Json<PlayControlRequest>>,
) -> ApiResult<PlaybackState> {
    let request = payload.map(|Json(payload)| payload).unwrap_or_default();
    let gate = state.playback_control_gate(&zone_id).await;
    let _guard = gate.lock().await;
    if let Some(playback) =
        replay_playback_command(&state, &zone_id, "play", &request.command).await?
    {
        return Ok(Json(playback));
    }
    let playback = if let Some(track_id) = request.track_id {
        play_track_on_zone(
            &state,
            &zone_id,
            track_id,
            request.position_ms.unwrap_or(0),
            &request.command,
        )
        .await?
    } else {
        resume_zone_internal(&state, &zone_id, &request.command).await?
    };
    record_playback_command(&state, &zone_id, "play", &request.command, &playback).await?;
    Ok(Json(playback))
}

pub(crate) async fn play_zone_collection(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    Json(payload): Json<PlayCollectionControlRequest>,
) -> ApiResult<serde_json::Value> {
    let gate = state.playback_control_gate(&zone_id).await;
    let _guard = gate.lock().await;
    if let Some(response) =
        replay_playback_command(&state, &zone_id, "play_collection", &payload.command).await?
    {
        return Ok(Json(response));
    }
    let request_started = tokio::time::Instant::now();
    let start_index = payload.start_index.unwrap_or(0);
    let index = usize::try_from(start_index)
        .ok()
        .filter(|index| *index < payload.track_ids.len())
        .ok_or_else(|| anyhow::anyhow!("collection start_index is out of range"))?;
    let track_id = payload.track_ids[index];
    let queue =
        core_db::replace_playback_queue(state.pool(), &zone_id, payload.queue_request()).await?;
    let queue_elapsed_ms = request_started.elapsed().as_millis();
    state.emit("playback.queue_changed", &queue);
    let playback = play_track_on_zone(&state, &zone_id, track_id, 0, &payload.command).await?;
    let total_elapsed_ms = request_started.elapsed().as_millis();
    let response = json!({
        "queue": queue,
        "playback": playback,
        "timing_ms": {
            "queue": queue_elapsed_ms,
            "playback": total_elapsed_ms.saturating_sub(queue_elapsed_ms),
            "total": total_elapsed_ms
        }
    });
    record_playback_command(
        &state,
        &zone_id,
        "play_collection",
        &payload.command,
        &response,
    )
    .await?;
    Ok(Json(response))
}

pub(crate) async fn play_many_zones(
    State(state): State<AppState>,
    Json(payload): Json<MultiZonePlayRequest>,
) -> ApiResult<Vec<PlaybackState>> {
    let mut states = Vec::new();
    for zone_id in payload.zone_ids {
        states.push(
            play_track_on_zone(
                &state,
                &zone_id,
                payload.track_id,
                payload.position_ms.unwrap_or(0),
                &PlaybackCommandContext::default(),
            )
            .await?,
        );
    }
    Ok(Json(states))
}

pub(crate) async fn transfer_zone(
    State(state): State<AppState>,
    Path(source_zone_id): Path<String>,
    Json(payload): Json<ZoneTransferRequest>,
) -> ApiResult<Vec<PlaybackState>> {
    if source_zone_id == payload.target_zone_id {
        return Ok(Json(vec![
            playback_state_for_zone(&state, &source_zone_id).await?,
        ]));
    }

    let source = playback_state_for_zone(&state, &source_zone_id).await?;
    let track_id = source
        .track_id
        .ok_or_else(|| anyhow::anyhow!("source zone {source_zone_id} has no active track"))?;

    let mut states = vec![
        play_track_on_zone(
            &state,
            &payload.target_zone_id,
            track_id,
            source.position_ms,
            &PlaybackCommandContext::default(),
        )
        .await?,
    ];
    if payload.stop_source {
        states.push(
            stop_zone_internal_with_reason(
                &state,
                &source_zone_id,
                "transferred",
                Some(payload.target_zone_id.as_str()),
                &PlaybackCommandContext::default(),
            )
            .await?,
        );
    }

    Ok(Json(states))
}

pub(crate) async fn pause_zone(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    payload: Option<Json<PlaybackControlRequest>>,
) -> ApiResult<PlaybackState> {
    let request = payload.map(|Json(payload)| payload).unwrap_or_default();
    let gate = state.playback_control_gate(&zone_id).await;
    let _guard = gate.lock().await;
    if let Some(playback) =
        replay_playback_command(&state, &zone_id, "pause", &request.command).await?
    {
        return Ok(Json(playback));
    }
    let playback = pause_zone_internal(&state, &zone_id, &request.command).await?;
    record_playback_command(&state, &zone_id, "pause", &request.command, &playback).await?;
    Ok(Json(playback))
}

pub(crate) async fn stop_zone(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    payload: Option<Json<PlaybackControlRequest>>,
) -> ApiResult<PlaybackState> {
    let request = payload.map(|Json(payload)| payload).unwrap_or_default();
    let gate = state.playback_control_gate(&zone_id).await;
    let _guard = gate.lock().await;
    if let Some(playback) =
        replay_playback_command(&state, &zone_id, "stop", &request.command).await?
    {
        return Ok(Json(playback));
    }
    let playback = stop_zone_internal(&state, &zone_id, &request.command).await?;
    record_playback_command(&state, &zone_id, "stop", &request.command, &playback).await?;
    Ok(Json(playback))
}

pub(crate) async fn seek_zone(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    Json(payload): Json<SeekControlRequest>,
) -> ApiResult<PlaybackState> {
    let gate = state.playback_control_gate(&zone_id).await;
    let _guard = gate.lock().await;
    if let Some(playback) =
        replay_playback_command(&state, &zone_id, "seek", &payload.command).await?
    {
        return Ok(Json(playback));
    }
    let playback =
        seek_zone_internal(&state, &zone_id, payload.position_ms, &payload.command).await?;
    record_playback_command(&state, &zone_id, "seek", &payload.command, &playback).await?;
    Ok(Json(playback))
}

pub(crate) async fn get_zone_queue(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
) -> ApiResult<PlaybackQueue> {
    Ok(Json(core_db::playback_queue(state.pool(), &zone_id).await?))
}

pub(crate) async fn replace_zone_queue(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    Json(payload): Json<ReplacePlaybackQueue>,
) -> ApiResult<PlaybackQueue> {
    let queue = core_db::replace_playback_queue(state.pool(), &zone_id, payload).await?;
    state.emit("playback.queue_changed", &queue);
    Ok(Json(queue))
}

pub(crate) async fn add_zone_queue_items(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    Json(payload): Json<AddPlaybackQueueItems>,
) -> ApiResult<PlaybackQueue> {
    let queue = core_db::add_playback_queue_items(
        state.pool(),
        &zone_id,
        payload.track_ids,
        payload.position,
    )
    .await?;
    state.emit("playback.queue_changed", &queue);
    Ok(Json(queue))
}

pub(crate) async fn remove_zone_queue_item(
    State(state): State<AppState>,
    Path((zone_id, item_id)): Path<(String, i64)>,
) -> ApiResult<PlaybackQueue> {
    let queue = core_db::remove_playback_queue_item(state.pool(), &zone_id, item_id).await?;
    state.emit("playback.queue_changed", &queue);
    Ok(Json(queue))
}

pub(crate) async fn move_zone_queue_item(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    Json(payload): Json<MovePlaybackQueueItem>,
) -> ApiResult<PlaybackQueue> {
    let queue =
        core_db::move_playback_queue_item(state.pool(), &zone_id, payload.from, payload.to).await?;
    state.emit("playback.queue_changed", &queue);
    Ok(Json(queue))
}

pub(crate) async fn update_zone_queue_mode(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    Json(payload): Json<PlaybackModeUpdate>,
) -> ApiResult<PlaybackQueue> {
    let queue = core_db::set_playback_mode(state.pool(), &zone_id, payload.mode).await?;
    state.emit("playback.queue_changed", &queue);
    Ok(Json(queue))
}

pub(crate) async fn next_zone_track(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    payload: Option<Json<PlaybackControlRequest>>,
) -> ApiResult<PlaybackState> {
    let request = payload.map(|Json(payload)| payload).unwrap_or_default();
    let gate = state.playback_control_gate(&zone_id).await;
    let _guard = gate.lock().await;
    if let Some(playback) =
        replay_playback_command(&state, &zone_id, "next", &request.command).await?
    {
        return Ok(Json(playback));
    }
    let playback = play_queue_step(&state, &zone_id, false, false, &request.command).await?;
    record_playback_command(&state, &zone_id, "next", &request.command, &playback).await?;
    Ok(Json(playback))
}

pub(crate) async fn previous_zone_track(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    payload: Option<Json<PlaybackControlRequest>>,
) -> ApiResult<PlaybackState> {
    let request = payload.map(|Json(payload)| payload).unwrap_or_default();
    let gate = state.playback_control_gate(&zone_id).await;
    let _guard = gate.lock().await;
    if let Some(playback) =
        replay_playback_command(&state, &zone_id, "previous", &request.command).await?
    {
        return Ok(Json(playback));
    }
    let playback = play_queue_step(&state, &zone_id, true, false, &request.command).await?;
    record_playback_command(&state, &zone_id, "previous", &request.command, &playback).await?;
    Ok(Json(playback))
}

pub(crate) async fn get_zone_volume(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
) -> ApiResult<ZoneVolume> {
    Ok(Json(core_db::zone_volume(state.pool(), &zone_id).await?))
}

pub(crate) async fn update_zone_volume(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    Json(payload): Json<VolumeControlRequest>,
) -> ApiResult<ZoneVolume> {
    let gate = state.playback_control_gate(&zone_id).await;
    let _guard = gate.lock().await;
    if let Some(volume) =
        replay_playback_command(&state, &zone_id, "volume", &payload.command).await?
    {
        return Ok(Json(volume));
    }
    if payload.mode == VolumeControlMode::System
        && (is_core_zone(&zone_id)
            || !state
                .inner
                .renderers
                .system_volume_writable_for_output(&zone_id)
                .await)
    {
        return Err(
            anyhow::anyhow!("system volume is not writable for playback zone {zone_id}").into(),
        );
    }
    let volume = core_db::set_zone_volume(
        state.pool(),
        &zone_id,
        payload.mode,
        payload.volume,
        payload.muted,
    )
    .await?;
    apply_zone_volume(&state, &volume, &payload.command).await?;
    state.emit("zone.volume_changed", &volume);
    record_playback_command(&state, &zone_id, "volume", &payload.command, &volume).await?;
    Ok(Json(volume))
}
