use super::*;

pub(crate) struct RendererCommandRequest<'a> {
    pub(crate) zone_id: &'a str,
    pub(crate) action: &'a str,
    pub(crate) track_id: Option<i64>,
    pub(crate) track_title: Option<String>,
    pub(crate) stream_path: Option<String>,
    pub(crate) position_ms: Option<u64>,
    pub(crate) volume: Option<f32>,
    pub(crate) muted: Option<bool>,
    pub(crate) context: &'a PlaybackCommandContext,
    pub(crate) expires_after_ms: u64,
}

pub(crate) async fn create_renderer_command(
    state: &AppState,
    request: RendererCommandRequest<'_>,
) -> Result<(String, RendererCommandPayload)> {
    let renderer_id = state
        .inner
        .renderers
        .renderer_id_for_output(request.zone_id)
        .await
        .ok_or_else(|| anyhow::anyhow!("playback zone {} is not registered", request.zone_id))?;
    let sequence = state
        .inner
        .renderers
        .next_command_sequence(request.zone_id)
        .await?;
    Ok((
        renderer_id,
        RendererCommandPayload {
            command_id: Uuid::now_v7(),
            sequence,
            issued_at: Some(Utc::now()),
            expires_after_ms: Some(request.expires_after_ms),
            origin_client_id: request.context.origin_client_id.clone(),
            intent_id: request.context.intent_id.clone(),
            target_output_id: request.zone_id.to_string(),
            action: request.action.to_string(),
            track_id: request.track_id,
            track_title: request.track_title,
            stream_path: request.stream_path,
            position_ms: request.position_ms,
            volume: request.volume,
            muted: request.muted,
            volume_mode: VolumeControlMode::Player,
        },
    ))
}

pub(crate) fn stamp_playback_command(
    playback: &mut PlaybackState,
    command: &RendererCommandPayload,
) {
    playback.command_sequence = Some(command.sequence);
    playback.origin_client_id = command.origin_client_id.clone();
    playback.intent_id = command.intent_id.clone();
}

impl Paging {
    pub(crate) fn limit(&self) -> u32 {
        self.limit.unwrap_or(50).clamp(1, 500)
    }

    pub(crate) fn offset(&self) -> u32 {
        self.offset.unwrap_or(0)
    }
}

#[derive(Debug, Deserialize)]
pub(crate) struct SearchParams {
    pub(crate) q: String,
    pub(crate) limit: Option<u32>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct HistoryQuery {
    pub(crate) limit: Option<u32>,
    pub(crate) offset: Option<u32>,
    pub(crate) from: Option<String>,
    pub(crate) to: Option<String>,
}

impl HistoryQuery {
    pub(crate) fn limit(&self) -> u32 {
        self.limit.unwrap_or(100).clamp(1, 500)
    }

    pub(crate) fn offset(&self) -> u32 {
        self.offset.unwrap_or(0)
    }
}

#[derive(Debug, Deserialize)]
pub(crate) struct StatsQuery {
    pub(crate) from: Option<String>,
    pub(crate) to: Option<String>,
    pub(crate) top_limit: Option<u32>,
}

pub(crate) fn apply_favorite_settings_to_playlist(
    settings: &FavoritesConfig,
    playlist: &mut PlaylistDetail,
) {
    apply_favorite_settings_to_tracks(settings, &mut playlist.tracks);
}

pub(crate) fn apply_favorite_settings_to_tracks(
    settings: &FavoritesConfig,
    tracks: &mut [protocol::TrackSummary],
) {
    for track in tracks {
        apply_favorite_settings_to_track(settings, track);
    }
}

pub(crate) fn apply_favorite_settings_to_track(
    settings: &FavoritesConfig,
    track: &mut protocol::TrackSummary,
) {
    if settings.treat_max_rating_as_favorite && has_max_tag_rating(track) {
        track.is_favorite = true;
    }
}

pub(crate) fn has_max_tag_rating(track: &protocol::TrackSummary) -> bool {
    matches!(
        (track.tag_rating, track.tag_rating_scale),
        (Some(rating), Some(scale)) if scale > 0 && rating >= scale
    )
}

pub(crate) async fn playback_state_for_zone(
    state: &AppState,
    zone_id: &str,
) -> Result<PlaybackState> {
    let mut playback = if is_core_zone(zone_id) {
        state.inner.playback.state_for_zone(zone_id).await
    } else {
        state
            .inner
            .renderers
            .state_for_output(zone_id)
            .await
            .ok_or_else(|| anyhow::anyhow!("playback zone {zone_id} is not registered"))?
    };
    playback.queue_revision = core_db::playback_queue(state.pool(), zone_id)
        .await?
        .revision;
    Ok(playback)
}

pub(crate) async fn play_queue_step(
    state: &AppState,
    zone_id: &str,
    previous: bool,
    automatic: bool,
    context: &PlaybackCommandContext,
) -> Result<PlaybackState> {
    match step_playback_queue_and_emit(state, zone_id, previous, automatic).await? {
        Some(track_id) => play_track_on_zone(state, zone_id, track_id, 0, context).await,
        None => {
            stop_zone_internal_with_reason(state, zone_id, "queue_completed", None, context).await
        }
    }
}

pub(crate) async fn step_playback_queue_and_emit(
    state: &AppState,
    zone_id: &str,
    previous: bool,
    automatic: bool,
) -> Result<Option<i64>> {
    let track_id = core_db::step_playback_queue(state.pool(), zone_id, previous, automatic).await?;
    let queue = core_db::playback_queue(state.pool(), zone_id).await?;
    state.emit("playback.queue_changed", &queue);
    Ok(track_id)
}

pub(crate) async fn apply_zone_volume(
    state: &AppState,
    volume: &ZoneVolume,
    context: &PlaybackCommandContext,
) -> Result<()> {
    let effective_volume = if volume.muted { 0.0 } else { volume.volume };
    if is_core_zone(&volume.zone_id) {
        if volume.mode == VolumeControlMode::System {
            anyhow::bail!("system volume is unavailable for Core-owned outputs");
        }
        state
            .inner
            .playback
            .set_volume_zone(&volume.zone_id, effective_volume)
            .await;
        return Ok(());
    }
    let playback = state
        .inner
        .renderers
        .state_for_output(&volume.zone_id)
        .await;
    let (renderer_id, mut command) = create_renderer_command(
        state,
        RendererCommandRequest {
            zone_id: &volume.zone_id,
            action: "volume",
            track_id: playback.as_ref().and_then(|state| state.track_id),
            track_title: playback.and_then(|state| state.track_title),
            stream_path: None,
            position_ms: None,
            volume: Some(volume.volume),
            muted: Some(volume.muted),
            context,
            expires_after_ms: VOLUME_COMMAND_TTL_MS,
        },
    )
    .await?;
    command.volume_mode = volume.mode;
    state.emit_renderer_command(&renderer_id, &command);
    Ok(())
}

pub(crate) async fn expire_offline_renderer_playback(state: &AppState) {
    for (previous, current) in state.inner.renderers.expire_offline_playback().await {
        record_playback_finish(
            state,
            &previous,
            "renderer_offline",
            "renderer_offline",
            None,
        )
        .await;
        state.emit("playback.state_changed", &current);
    }
}

pub(crate) async fn play_track_on_zone(
    state: &AppState,
    zone_id: &str,
    track_id: i64,
    position_ms: u64,
    context: &PlaybackCommandContext,
) -> Result<PlaybackState> {
    play_track_on_zone_with_queue_selection(state, zone_id, track_id, position_ms, context, true)
        .await
}

/// Starts a track after a v3 command has already selected its stable queue
/// occurrence. Selecting by track ID here would jump to the first duplicate
/// occurrence and lose the v3 queue cursor.
pub(crate) async fn play_track_on_zone_preserving_queue(
    state: &AppState,
    zone_id: &str,
    track_id: i64,
    position_ms: u64,
    context: &PlaybackCommandContext,
) -> Result<PlaybackState> {
    play_track_on_zone_with_queue_selection(state, zone_id, track_id, position_ms, context, false)
        .await
}

async fn play_track_on_zone_with_queue_selection(
    state: &AppState,
    zone_id: &str,
    track_id: i64,
    position_ms: u64,
    context: &PlaybackCommandContext,
    select_queue_track: bool,
) -> Result<PlaybackState> {
    let previous = playback_state_for_zone(state, zone_id).await.ok();
    let queue = if select_queue_track {
        let queue =
            core_db::set_playback_queue_current_track(state.pool(), zone_id, track_id).await?;
        state.emit("playback.queue_changed", &queue);
        queue
    } else {
        core_db::playback_queue(state.pool(), zone_id).await?
    };
    let detail = core_db::track_detail(state.pool(), track_id).await?;
    let track_title = detail.track.title.clone();

    let mut playback = if is_core_zone(zone_id) {
        let output_id = zone_id.starts_with("cpal:").then_some(zone_id);
        let playback = state
            .inner
            .playback
            .play_track_on_zone(
                zone_id,
                output_id,
                detail.track.id,
                detail.track.title,
                detail.file_path,
                position_ms,
            )
            .await?;
        if zone_id == "local" {
            core_db::set_zone_state(state.pool(), zone_id, "playing").await?;
        }
        playback
    } else {
        let (renderer_id, command) = create_renderer_command(
            state,
            RendererCommandRequest {
                zone_id,
                action: "play",
                track_id: Some(detail.track.id),
                track_title: Some(track_title.clone()),
                stream_path: Some(format!("/tracks/{track_id}/stream")),
                position_ms: Some(position_ms),
                volume: None,
                muted: None,
                context,
                expires_after_ms: TRANSPORT_COMMAND_TTL_MS,
            },
        )
        .await?;
        info!(
            event = "renderer_command_sent",
            command_id = %command.command_id,
            command_sequence = command.sequence,
            renderer_id = %renderer_id,
            zone_id,
            track_id,
            "sent renderer playback command"
        );
        let playback = state
            .inner
            .renderers
            .update_state(PlaybackState {
                zone_id: zone_id.to_string(),
                state: PlaybackTransportState::Playing,
                track_id: Some(detail.track.id),
                track_title: Some(track_title),
                position_ms,
                queue_revision: queue.revision,
                command_sequence: Some(command.sequence),
                origin_client_id: command.origin_client_id.clone(),
                intent_id: command.intent_id.clone(),
            })
            .await?;
        state.emit_renderer_command(&renderer_id, &command);
        playback
    };
    playback.queue_revision = queue.revision;
    let volume = core_db::zone_volume(state.pool(), zone_id).await?;
    apply_zone_volume(state, &volume, &PlaybackCommandContext::default()).await?;

    if let Some(previous) = previous.as_ref() {
        if previous.track_id.is_some() {
            record_playback_finish(state, previous, "replaced", "cut_out", None).await;
        }
    }
    record_playback_start(state, &playback).await;
    state.emit("playback.state_changed", &playback);
    Ok(playback)
}

pub(crate) async fn resume_zone_internal(
    state: &AppState,
    zone_id: &str,
    context: &PlaybackCommandContext,
) -> Result<PlaybackState> {
    let playback = if is_core_zone(zone_id) {
        if zone_id == "local" {
            core_db::set_zone_state(state.pool(), zone_id, "playing").await?;
        }
        state.inner.playback.resume_zone(zone_id).await
    } else {
        let mut playback = state
            .inner
            .renderers
            .state_for_output(zone_id)
            .await
            .ok_or_else(|| anyhow::anyhow!("playback zone {zone_id} is not registered"))?;
        playback.state = PlaybackTransportState::Playing;
        let (renderer_id, command) = create_renderer_command(
            state,
            RendererCommandRequest {
                zone_id,
                action: "resume",
                track_id: playback.track_id,
                track_title: playback.track_title.clone(),
                stream_path: playback
                    .track_id
                    .map(|track_id| format!("/tracks/{track_id}/stream")),
                position_ms: Some(playback.position_ms),
                volume: None,
                muted: None,
                context,
                expires_after_ms: TRANSPORT_COMMAND_TTL_MS,
            },
        )
        .await?;
        stamp_playback_command(&mut playback, &command);
        let playback = state.inner.renderers.update_state(playback).await?;
        state.emit_renderer_command(&renderer_id, &command);
        playback
    };
    record_playback_update(state, &playback, "resume").await;
    state.emit("playback.state_changed", &playback);
    Ok(playback)
}

pub(crate) async fn pause_zone_internal(
    state: &AppState,
    zone_id: &str,
    context: &PlaybackCommandContext,
) -> Result<PlaybackState> {
    let playback = if is_core_zone(zone_id) {
        if zone_id == "local" {
            core_db::set_zone_state(state.pool(), zone_id, "paused").await?;
        }
        state.inner.playback.pause_zone(zone_id).await
    } else {
        let mut playback = state
            .inner
            .renderers
            .state_for_output(zone_id)
            .await
            .ok_or_else(|| anyhow::anyhow!("playback zone {zone_id} is not registered"))?;
        playback.state = PlaybackTransportState::Paused;
        let (renderer_id, command) = create_renderer_command(
            state,
            RendererCommandRequest {
                zone_id,
                action: "pause",
                track_id: playback.track_id,
                track_title: playback.track_title.clone(),
                stream_path: None,
                position_ms: None,
                volume: None,
                muted: None,
                context,
                expires_after_ms: TRANSPORT_COMMAND_TTL_MS,
            },
        )
        .await?;
        stamp_playback_command(&mut playback, &command);
        let playback = state.inner.renderers.update_state(playback).await?;
        state.emit_renderer_command(&renderer_id, &command);
        playback
    };
    record_playback_update(state, &playback, "pause").await;
    state.emit("playback.state_changed", &playback);
    Ok(playback)
}

pub(crate) async fn stop_zone_internal(
    state: &AppState,
    zone_id: &str,
    context: &PlaybackCommandContext,
) -> Result<PlaybackState> {
    stop_zone_internal_with_reason(state, zone_id, "stopped", None, context).await
}

pub(crate) async fn stop_zone_internal_with_reason(
    state: &AppState,
    zone_id: &str,
    reason: &str,
    related_zone_id: Option<&str>,
    context: &PlaybackCommandContext,
) -> Result<PlaybackState> {
    let previous = playback_state_for_zone(state, zone_id).await.ok();
    let playback = if is_core_zone(zone_id) {
        if zone_id == "local" {
            core_db::set_zone_state(state.pool(), zone_id, "stopped").await?;
        }
        state.inner.playback.stop_zone(zone_id).await
    } else {
        let (renderer_id, command) = create_renderer_command(
            state,
            RendererCommandRequest {
                zone_id,
                action: "stop",
                track_id: None,
                track_title: None,
                stream_path: None,
                position_ms: None,
                volume: None,
                muted: None,
                context,
                expires_after_ms: TRANSPORT_COMMAND_TTL_MS,
            },
        )
        .await?;
        let playback = state
            .inner
            .renderers
            .update_state(PlaybackState {
                zone_id: zone_id.to_string(),
                state: PlaybackTransportState::Stopped,
                track_id: None,
                track_title: None,
                position_ms: 0,
                queue_revision: 0,
                command_sequence: Some(command.sequence),
                origin_client_id: command.origin_client_id.clone(),
                intent_id: command.intent_id.clone(),
            })
            .await?;
        state.emit_renderer_command(&renderer_id, &command);
        playback
    };
    if let Some(previous) = previous.as_ref() {
        record_playback_finish(state, previous, reason, "stop", related_zone_id).await;
    }
    state.emit("playback.state_changed", &playback);
    Ok(playback)
}

pub(crate) async fn seek_zone_internal(
    state: &AppState,
    zone_id: &str,
    position_ms: u64,
    context: &PlaybackCommandContext,
) -> Result<PlaybackState> {
    let playback = if is_core_zone(zone_id) {
        state.inner.playback.seek_zone(zone_id, position_ms).await?
    } else {
        let mut playback = state
            .inner
            .renderers
            .state_for_output(zone_id)
            .await
            .ok_or_else(|| anyhow::anyhow!("playback zone {zone_id} is not registered"))?;
        playback.state = PlaybackTransportState::Playing;
        playback.position_ms = position_ms;
        let (renderer_id, command) = create_renderer_command(
            state,
            RendererCommandRequest {
                zone_id,
                action: "seek",
                track_id: playback.track_id,
                track_title: playback.track_title.clone(),
                stream_path: playback
                    .track_id
                    .map(|track_id| format!("/tracks/{track_id}/stream")),
                position_ms: Some(position_ms),
                volume: None,
                muted: None,
                context,
                expires_after_ms: TRANSPORT_COMMAND_TTL_MS,
            },
        )
        .await?;
        stamp_playback_command(&mut playback, &command);
        let playback = state.inner.renderers.update_state(playback).await?;
        state.emit_renderer_command(&renderer_id, &command);
        playback
    };
    record_playback_update(state, &playback, "seek").await;
    state.emit("playback.position", &playback);
    Ok(playback)
}

pub(crate) async fn record_renderer_state_transition(
    state: &AppState,
    previous: Option<PlaybackState>,
    current: &PlaybackState,
) {
    match current.state {
        PlaybackTransportState::Stopped => {
            if let Some(previous) = previous.as_ref().filter(|state| state.track_id.is_some()) {
                record_playback_finish(state, previous, "completed", "completed", None).await;
            }
        }
        PlaybackTransportState::Paused => {
            record_playback_update(state, current, "pause").await;
        }
        PlaybackTransportState::Playing => {
            record_playback_update(state, current, "progress").await;
        }
    }
}

pub(crate) async fn record_playback_start(state: &AppState, playback: &PlaybackState) {
    let Some(track_id) = playback.track_id else {
        return;
    };
    let track_title = playback
        .track_title
        .clone()
        .unwrap_or_else(|| format!("Track {track_id}"));
    if let Err(error) = core_db::finish_open_playback_session(
        state.pool(),
        &playback.zone_id,
        playback.position_ms,
        "replaced",
    )
    .await
    {
        error!(error = %error, zone_id = %playback.zone_id, "failed to close previous playback session");
    }
    if let Err(error) = core_db::start_playback_session(
        state.pool(),
        &playback.zone_id,
        track_id,
        &track_title,
        playback.position_ms,
    )
    .await
    {
        error!(error = %error, zone_id = %playback.zone_id, "failed to start playback session");
    }
    record_playback_event(state, playback, "play_start", None, None).await;
}

pub(crate) async fn record_playback_update(
    state: &AppState,
    playback: &PlaybackState,
    event_type: &str,
) {
    if playback.track_id.is_none() {
        return;
    }
    if let Err(error) = core_db::update_open_playback_session_position(
        state.pool(),
        &playback.zone_id,
        playback.position_ms,
    )
    .await
    {
        error!(error = %error, zone_id = %playback.zone_id, "failed to update playback session");
    }
    if event_type != "progress" {
        record_playback_event(state, playback, event_type, None, None).await;
    }
}

pub(crate) async fn record_playback_finish(
    state: &AppState,
    playback: &PlaybackState,
    reason: &str,
    event_type: &str,
    related_zone_id: Option<&str>,
) {
    if playback.track_id.is_none() {
        return;
    }
    if let Err(error) = core_db::finish_open_playback_session(
        state.pool(),
        &playback.zone_id,
        playback.position_ms,
        reason,
    )
    .await
    {
        error!(error = %error, zone_id = %playback.zone_id, "failed to finish playback session");
    }
    record_playback_event(state, playback, event_type, related_zone_id, Some(reason)).await;
}

pub(crate) async fn record_playback_event(
    state: &AppState,
    playback: &PlaybackState,
    event_type: &str,
    related_zone_id: Option<&str>,
    reason: Option<&str>,
) {
    if let Err(error) = core_db::record_playback_event(
        state.pool(),
        core_db::PlaybackEventIngest {
            zone_id: playback.zone_id.clone(),
            event_type: event_type.to_string(),
            track_id: playback.track_id,
            track_title: playback.track_title.clone(),
            position_ms: Some(playback.position_ms),
            related_zone_id: related_zone_id.map(ToOwned::to_owned),
            reason: reason.map(ToOwned::to_owned),
        },
    )
    .await
    {
        error!(error = %error, zone_id = %playback.zone_id, "failed to record playback event");
    }
}

pub(crate) fn is_core_zone(zone_id: &str) -> bool {
    zone_id == "local" || zone_id.starts_with("cpal:")
}
