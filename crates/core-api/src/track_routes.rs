use super::*;

pub(crate) async fn list_tracks(
    State(state): State<AppState>,
    Query(paging): Query<Paging>,
) -> ApiResult<Vec<protocol::TrackSummary>> {
    let mut tracks = core_db::list_tracks(state.pool(), paging.limit(), paging.offset()).await?;
    apply_favorite_settings_to_tracks(&state.config().favorites, &mut tracks);
    Ok(Json(tracks))
}

pub(crate) async fn track_detail(
    State(state): State<AppState>,
    Path(track_id): Path<i64>,
) -> ApiResult<protocol::TrackDetail> {
    let mut detail = core_db::track_detail(state.pool(), track_id).await?;
    fill_missing_lyrics_from_file(&mut detail).await;
    enrich_lyrics(&mut detail);
    apply_favorite_settings_to_track(&state.config().favorites, &mut detail.track);
    Ok(Json(detail))
}

pub(crate) async fn track_media_profile(
    State(state): State<AppState>,
    Path(track_id): Path<i64>,
) -> ApiResult<Option<protocol::TrackMediaProfile>> {
    Ok(Json(
        core_db::track_media_profile(state.pool(), track_id).await?,
    ))
}

pub(crate) async fn track_recording_candidates(
    State(state): State<AppState>,
    Path(track_id): Path<i64>,
) -> ApiResult<Vec<protocol::RecordingLinkCandidate>> {
    Ok(Json(
        core_db::recording_link_candidates(state.pool(), track_id, 50).await?,
    ))
}

pub(crate) async fn link_track_recording(
    State(state): State<AppState>,
    Path(track_id): Path<i64>,
    Json(request): Json<LinkTrackRecordingRequest>,
) -> ApiResult<protocol::TrackMediaProfile> {
    let media =
        core_db::link_track_to_recording(state.pool(), track_id, request.source_track_id).await?;
    state
        .bump_library_revision("release track linked to recording")
        .await;
    state.emit(
        "track.recording_changed",
        json!({
            "track_id": track_id,
            "recording_id": media.recording.id,
            "action": "linked",
        }),
    );
    Ok(Json(media))
}

pub(crate) async fn detach_track_recording(
    State(state): State<AppState>,
    Path(track_id): Path<i64>,
) -> ApiResult<protocol::TrackMediaProfile> {
    let media = core_db::detach_track_recording(state.pool(), track_id).await?;
    state
        .bump_library_revision("release track detached from recording")
        .await;
    state.emit(
        "track.recording_changed",
        json!({
            "track_id": track_id,
            "recording_id": media.recording.id,
            "action": "detached",
        }),
    );
    Ok(Json(media))
}

pub(crate) async fn track_edit_snapshot(
    State(state): State<AppState>,
    Path(track_id): Path<i64>,
) -> ApiResult<protocol::TrackEditSnapshot> {
    let mut snapshot = core_db::track_edit_snapshot(state.pool(), track_id).await?;
    fill_missing_lyrics_from_file(&mut snapshot.detail).await;
    enrich_lyrics(&mut snapshot.detail);
    apply_favorite_settings_to_track(&state.config().favorites, &mut snapshot.detail.track);
    Ok(Json(snapshot))
}

pub(crate) async fn update_track_metadata(
    State(state): State<AppState>,
    Path(track_id): Path<i64>,
    Json(update): Json<TrackMetadataUpdate>,
) -> ApiResult<protocol::TrackEditSnapshot> {
    let parsed = update.lyrics.as_ref().map(|lyrics| {
        lyrics_engine::parse_lyrics(
            &lyrics.kind,
            &lyrics.text,
            lyrics.translation.as_deref(),
            lyrics.pronunciation.as_deref(),
            lyrics.offset_ms,
        )
        .cues
    });
    let mut snapshot =
        core_db::update_track_metadata(state.pool(), track_id, &update, parsed.as_deref()).await?;
    enrich_lyrics(&mut snapshot.detail);
    apply_favorite_settings_to_track(&state.config().favorites, &mut snapshot.detail.track);
    state.bump_library_revision("track metadata updated").await;
    state.emit(
        "track.metadata_changed",
        json!({
            "track_id": track_id,
            "revision": snapshot.revision,
            "lyrics_changed": update.lyrics.is_some(),
        }),
    );
    Ok(Json(snapshot))
}

#[derive(Debug, Deserialize)]
pub(crate) struct WaveformQuery {
    bins: Option<usize>,
}

pub(crate) async fn track_waveform(
    State(state): State<AppState>,
    Path(track_id): Path<i64>,
    Query(query): Query<WaveformQuery>,
) -> ApiResult<protocol::TrackWaveform> {
    let detail = core_db::track_detail(state.pool(), track_id).await?;
    let path = PathBuf::from(&detail.file_path);
    let bins = query.bins.unwrap_or(768).clamp(64, 4096);
    let cache_key = format!("{}\0{}\0{bins}", detail.file_path, detail.modified_at);
    let cached = state
        .inner
        .waveform_cache
        .read()
        .await
        .get(&cache_key)
        .cloned();
    let peaks = if let Some(peaks) = cached {
        peaks
    } else {
        let peaks =
            tokio::task::spawn_blocking(move || audio_engine::extract_waveform(&path, bins))
                .await
                .map_err(anyhow::Error::from)??;
        let mut cache = state.inner.waveform_cache.write().await;
        if cache.len() >= 256 {
            cache.clear();
        }
        cache.insert(cache_key, peaks.clone());
        peaks
    };
    Ok(Json(protocol::TrackWaveform {
        track_id,
        duration_ms: detail.track.duration_ms,
        peaks,
    }))
}

pub(crate) async fn track_lyrics(
    State(state): State<AppState>,
    Path(track_id): Path<i64>,
) -> ApiResult<Option<protocol::LyricPayload>> {
    let mut detail = core_db::track_detail(state.pool(), track_id).await?;
    fill_missing_lyrics_from_file(&mut detail).await;
    enrich_lyrics(&mut detail);
    Ok(Json(detail.lyrics))
}

pub(crate) async fn fill_missing_lyrics_from_file(detail: &mut protocol::TrackDetail) {
    if detail
        .lyrics
        .as_ref()
        .is_some_and(|lyrics| !lyrics.text.trim().is_empty())
    {
        return;
    }
    let path = PathBuf::from(&detail.file_path);
    match tokio::task::spawn_blocking(move || library_scanner::extract_lyrics_from_path(&path))
        .await
    {
        Ok(Ok(Some((kind, text)))) if !text.trim().is_empty() => {
            detail.lyrics = Some(protocol::LyricPayload {
                kind,
                text,
                language: None,
                translation: None,
                pronunciation: None,
                offset_ms: 0,
                source: "file".to_string(),
                revision: 0,
                cues: Vec::new(),
            });
        }
        _ => {}
    }
}

pub(crate) fn enrich_lyrics(detail: &mut protocol::TrackDetail) {
    let Some(lyrics) = detail.lyrics.as_mut() else {
        return;
    };
    if !lyrics.cues.is_empty() {
        return;
    }
    lyrics.cues = lyrics_engine::parse_lyrics(
        &lyrics.kind,
        &lyrics.text,
        lyrics.translation.as_deref(),
        lyrics.pronunciation.as_deref(),
        lyrics.offset_ms,
    )
    .cues;
}

pub(crate) async fn track_stream(
    State(state): State<AppState>,
    Path(track_id): Path<i64>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let (path, extension) = core_db::track_stream_source(state.pool(), track_id).await?;
    stream_file_response(std::path::PathBuf::from(path), &extension, &headers).await
}

pub(crate) async fn stream_file_response(
    path: PathBuf,
    extension: &str,
    headers: &HeaderMap,
) -> Result<Response, ApiError> {
    let mut file = tokio::fs::File::open(&path)
        .await
        .map_err(anyhow::Error::from)?;
    let file_len = file.metadata().await.map_err(anyhow::Error::from)?.len();
    if file_len == 0 {
        let mut response = Response::new(Body::empty());
        response.headers_mut().insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static(content_type_for_extension(extension)),
        );
        response
            .headers_mut()
            .insert(header::CONTENT_LENGTH, HeaderValue::from_static("0"));
        return Ok(response);
    }

    let (status, start, end) = match parse_range(headers, file_len) {
        Some((start, end)) => (StatusCode::PARTIAL_CONTENT, start, end),
        None => (StatusCode::OK, 0, file_len.saturating_sub(1)),
    };
    let content_len = end.saturating_sub(start).saturating_add(1);

    file.seek(SeekFrom::Start(start))
        .await
        .map_err(anyhow::Error::from)?;
    let body = Body::from_stream(ReaderStream::new(file.take(content_len)));
    let mut response = Response::new(body);
    *response.status_mut() = status;
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static(content_type_for_extension(extension)),
    );
    response
        .headers_mut()
        .insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    response.headers_mut().insert(
        header::CONTENT_LENGTH,
        HeaderValue::from_str(&content_len.to_string()).map_err(anyhow::Error::from)?,
    );
    if status == StatusCode::PARTIAL_CONTENT {
        response.headers_mut().insert(
            header::CONTENT_RANGE,
            HeaderValue::from_str(&format!("bytes {start}-{end}/{file_len}"))
                .map_err(anyhow::Error::from)?,
        );
    }
    Ok(response)
}
