use super::*;

pub(crate) async fn status(State(state): State<AppState>) -> ApiResult<CoreStatus> {
    let counts = core_db::library_counts(state.pool()).await?;
    Ok(Json(CoreStatus {
        name: "IntMusic Local Music Core".to_string(),
        display_name: core_display_name(&state.config()),
        version: env!("CARGO_PKG_VERSION").to_string(),
        api_version: "v1".to_string(),
        server_id: state.inner.server_id.to_string(),
        catalog_epoch: state.inner.catalog_epoch.clone(),
        bind_address: state.inner.bind_address.to_string(),
        discovery_service: state.inner.discovery_service.clone(),
        started_at: state.inner.started_at,
        library_revision: state.inner.library_revision.load(Ordering::SeqCst),
        database_path: state.inner.paths.database_file.display().to_string(),
        counts,
    }))
}

pub(crate) fn core_display_name(config: &CoreConfig) -> String {
    config
        .server
        .alias
        .as_deref()
        .map(str::trim)
        .filter(|alias| !alias.is_empty())
        .unwrap_or("Core local")
        .to_string()
}

pub(crate) async fn list_roots(
    State(state): State<AppState>,
) -> ApiResult<Vec<protocol::LibraryRoot>> {
    Ok(Json(core_db::list_library_roots(state.pool()).await?))
}

pub(crate) async fn add_root(
    State(state): State<AppState>,
    Json(payload): Json<NewLibraryRoot>,
) -> ApiResult<protocol::LibraryRoot> {
    let root = core_db::add_library_root(state.pool(), payload.path.as_ref()).await?;
    state.bump_library_revision("library_root_added").await;
    Ok(Json(root))
}

pub(crate) async fn remove_root(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> ApiResult<serde_json::Value> {
    core_db::remove_library_root(state.pool(), id).await?;
    state.bump_library_revision("library_root_removed").await;
    Ok(Json(json!({ "removed": true })))
}

pub(crate) async fn list_client_library_roots(
    State(state): State<AppState>,
) -> ApiResult<Vec<protocol::ClientLibraryRootStatus>> {
    Ok(Json(
        core_db::list_client_library_roots(state.pool()).await?,
    ))
}

pub(crate) async fn upsert_client_library_manifest(
    State(state): State<AppState>,
    Json(payload): Json<ClientLibraryManifestRequest>,
) -> ApiResult<protocol::ClientLibraryManifestResult> {
    let device_id = payload.device_id.clone();
    let root_external_id = payload.root.external_id.clone();
    let scan_id = payload.scan_id.clone();
    let result = core_db::upsert_client_library_manifest(state.pool(), &payload).await?;
    if !result.duplicate_batch {
        state
            .bump_library_revision("client library manifest updated")
            .await;
        state.emit(
            "library.client_manifest_changed",
            json!({
                "device_id": device_id,
                "root_external_id": root_external_id,
                "scan_id": scan_id,
                "complete": result.complete,
                "accepted_files": result.accepted_files,
                "missing_files": result.missing_files,
            }),
        );
    }
    Ok(Json(result))
}

pub(crate) async fn list_client_library_pending_files(
    State(state): State<AppState>,
) -> ApiResult<Vec<protocol::ClientLibraryPendingFile>> {
    Ok(Json(
        core_db::list_client_library_pending_files(state.pool()).await?,
    ))
}

pub(crate) async fn resolve_client_library_file(
    State(state): State<AppState>,
    Path(file_id): Path<i64>,
    Json(payload): Json<ResolveClientLibraryFileRequest>,
) -> ApiResult<protocol::ResolveClientLibraryFileResult> {
    let result = core_db::resolve_client_library_file(
        state.pool(),
        file_id,
        &payload.action,
        payload.target_track_id,
        payload.metadata.as_ref(),
    )
    .await?;
    state
        .bump_library_revision("client library file resolved")
        .await;
    state.emit(
        "library.client_file_resolved",
        json!({
            "file_id": file_id,
            "action": result.action,
            "track_id": result.track_id,
            "media_variant_id": result.media_variant_id,
            "scan_status": result.scan_status,
        }),
    );
    Ok(Json(result))
}

pub(crate) async fn remove_client_library_root(
    State(state): State<AppState>,
    Path((device_id, root_external_id)): Path<(String, String)>,
) -> ApiResult<serde_json::Value> {
    core_db::remove_client_library_root(state.pool(), &device_id, &root_external_id).await?;
    state
        .bump_library_revision("client library root removed")
        .await;
    state.emit(
        "library.client_manifest_changed",
        json!({
            "device_id": device_id,
            "root_external_id": root_external_id,
            "removed": true,
        }),
    );
    Ok(Json(json!({ "removed": true })))
}

pub(crate) async fn apply_client_mutations(
    State(state): State<AppState>,
    Json(payload): Json<ClientMutationBatchRequest>,
) -> ApiResult<protocol::ClientMutationBatchResult> {
    let result = core_db::apply_client_mutations(state.pool(), &payload).await?;
    if !result.applied_ids.is_empty() {
        let favorite_changed = payload.mutations.iter().any(|mutation| {
            mutation.kind == "favorite"
                && result.applied_ids.iter().any(|id| id == mutation.id.trim())
        });
        if favorite_changed {
            state
                .bump_library_revision("offline favorite mutations applied")
                .await;
        }
        state.emit(
            "client.mutations_applied",
            json!({
                "device_id": payload.device_id,
                "applied_ids": result.applied_ids,
                "library_changed": favorite_changed,
            }),
        );
    }
    Ok(Json(result))
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct ClientSyncSnapshotQuery {
    device_id: Option<String>,
}

pub(crate) async fn client_sync_snapshot(
    State(state): State<AppState>,
    Query(query): Query<ClientSyncSnapshotQuery>,
) -> ApiResult<ClientSyncSnapshot> {
    // Read the cursor first. Any write racing with this snapshot will therefore
    // remain visible to the next /changes request instead of being skipped.
    let cursor = core_db::sync_cursor(state.pool()).await?;
    let config = state.config();
    let mut albums = Vec::new();
    let mut artists = Vec::new();
    let mut tracks = Vec::new();
    let mut offset = 0;
    const PAGE_SIZE: u32 = 1_000;
    loop {
        let page = core_db::list_albums(state.pool(), PAGE_SIZE, offset).await?;
        let count = page.len();
        albums.extend(page);
        if count < PAGE_SIZE as usize {
            break;
        }
        offset += PAGE_SIZE;
    }
    offset = 0;
    loop {
        let page = core_db::list_artists(state.pool(), PAGE_SIZE, offset).await?;
        let count = page.len();
        artists.extend(page);
        if count < PAGE_SIZE as usize {
            break;
        }
        offset += PAGE_SIZE;
    }
    offset = 0;
    loop {
        let mut page = core_db::list_tracks(state.pool(), PAGE_SIZE, offset).await?;
        let count = page.len();
        apply_favorite_settings_to_tracks(&config.favorites, &mut page);
        tracks.extend(page);
        if count < PAGE_SIZE as usize {
            break;
        }
        offset += PAGE_SIZE;
    }
    let playlists =
        core_db::list_playlists(state.pool(), config.favorites.treat_max_rating_as_favorite)
            .await?;
    Ok(Json(ClientSyncSnapshot {
        server_id: state.inner.server_id.to_string(),
        catalog_epoch: state.inner.catalog_epoch.clone(),
        cursor,
        generated_at: Utc::now(),
        albums,
        artists,
        tracks,
        playlists,
        playback_history: core_db::list_playback_events(state.pool(), 250, 0, None, None).await?,
        playback_stats: core_db::playback_stats(state.pool(), None, None, 50).await?,
        library_roots: core_db::list_library_roots(state.pool()).await?,
        client_library_roots: core_db::list_client_library_roots(state.pool()).await?,
        client_file_bindings: match query.device_id.as_deref() {
            Some(device_id) if !device_id.trim().is_empty() => {
                core_db::client_library_copy_bindings(state.pool(), device_id).await?
            }
            _ => Vec::new(),
        },
        settings: serde_json::to_value(config).map_err(anyhow::Error::from)?,
    }))
}

#[derive(Debug, Deserialize)]
pub(crate) struct ClientSyncChangesQuery {
    after: Option<u64>,
    limit: Option<u32>,
}

pub(crate) async fn client_sync_changes(
    State(state): State<AppState>,
    Query(query): Query<ClientSyncChangesQuery>,
) -> ApiResult<ClientSyncChanges> {
    let after = query.after.unwrap_or(0);
    let changes =
        core_db::client_sync_changes(state.pool(), after, query.limit.unwrap_or(500)).await?;
    let cursor = core_db::sync_cursor(state.pool()).await?;
    Ok(Json(ClientSyncChanges {
        server_id: state.inner.server_id.to_string(),
        after,
        cursor,
        requires_snapshot: !changes.is_empty(),
        changes,
    }))
}

#[derive(Debug, Deserialize)]
pub(crate) struct ClientSyncDetailsQuery {
    kind: String,
    after_id: Option<i64>,
    limit: Option<u32>,
}

pub(crate) async fn client_sync_details(
    State(state): State<AppState>,
    Query(query): Query<ClientSyncDetailsQuery>,
) -> ApiResult<serde_json::Value> {
    let kind = query.kind.trim().to_ascii_lowercase();
    let after_id = query.after_id.unwrap_or(0).max(0);
    let limit = query.limit.unwrap_or(100).clamp(1, 200);
    let ids = core_db::client_sync_detail_ids(state.pool(), &kind, after_id, limit).await?;
    let config = state.config();
    let mut items = Vec::with_capacity(ids.len());
    for id in &ids {
        let detail = match kind.as_str() {
            "track" => {
                let mut detail = core_db::track_detail(state.pool(), *id).await?;
                apply_favorite_settings_to_track(&config.favorites, &mut detail.track);
                serde_json::to_value(detail)
            }
            "album" => {
                let mut detail = core_db::album_detail(state.pool(), *id).await?;
                apply_favorite_settings_to_tracks(&config.favorites, &mut detail.tracks);
                serde_json::to_value(detail)
            }
            "artist" => {
                let mut detail = core_db::artist_detail(state.pool(), *id).await?;
                apply_favorite_settings_to_tracks(&config.favorites, &mut detail.tracks);
                serde_json::to_value(detail)
            }
            "playlist" => {
                let mut detail = core_db::playlist_detail(
                    state.pool(),
                    *id,
                    config.favorites.treat_max_rating_as_favorite,
                )
                .await?;
                apply_favorite_settings_to_playlist(&config.favorites, &mut detail);
                serde_json::to_value(detail)
            }
            _ => unreachable!(),
        }
        .map_err(anyhow::Error::from)?;
        items.push(json!({ "id": id, "detail": detail }));
    }
    let next_after_id = ids.last().copied().unwrap_or(after_id);
    Ok(Json(json!({
        "server_id": state.inner.server_id.to_string(),
        "cursor": core_db::sync_cursor(state.pool()).await?,
        "kind": kind,
        "items": items,
        "next_after_id": next_after_id,
        "has_more": ids.len() == limit as usize,
    })))
}
