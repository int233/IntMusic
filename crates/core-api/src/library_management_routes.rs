use super::*;

#[derive(Debug, Default, Deserialize)]
pub(crate) struct LibraryFilesQuery {
    search: Option<String>,
    device_id: Option<String>,
    root_id: Option<i64>,
    extension: Option<String>,
    status: Option<String>,
    issue: Option<String>,
    limit: Option<u32>,
    offset: Option<u32>,
}

pub(crate) async fn library_management_summary(
    State(state): State<AppState>,
) -> ApiResult<protocol::LibraryManagementSummary> {
    Ok(Json(
        core_db::library_management_summary(state.pool()).await?,
    ))
}

pub(crate) async fn list_library_management_files(
    State(state): State<AppState>,
    Query(query): Query<LibraryFilesQuery>,
) -> ApiResult<protocol::LibraryFilePage> {
    Ok(Json(
        core_db::list_library_files(
            state.pool(),
            &core_db::LibraryFileQuery {
                search: query.search,
                device_id: query.device_id,
                root_id: query.root_id,
                extension: query.extension,
                status: query.status,
                issue: query.issue,
                file_id: None,
                limit: query.limit.unwrap_or(100),
                offset: query.offset.unwrap_or(0),
            },
        )
        .await?,
    ))
}

pub(crate) async fn library_management_file_detail(
    State(state): State<AppState>,
    Path(file_id): Path<i64>,
) -> ApiResult<protocol::LibraryFileDetail> {
    Ok(Json(
        core_db::library_file_detail(state.pool(), file_id).await?,
    ))
}

pub(crate) async fn list_library_management_devices(
    State(state): State<AppState>,
) -> ApiResult<Vec<protocol::LibraryDeviceSummary>> {
    Ok(Json(core_db::list_library_devices(state.pool()).await?))
}

pub(crate) async fn manage_library_file(
    State(state): State<AppState>,
    Path(file_id): Path<i64>,
    Json(payload): Json<protocol::LibraryFileActionRequest>,
) -> ApiResult<protocol::LibraryManagementActionResult> {
    let result = core_db::manage_library_file(state.pool(), file_id, &payload.action).await?;
    state
        .bump_library_revision("library file inventory changed")
        .await;
    Ok(Json(result))
}

pub(crate) async fn manage_library_files(
    State(state): State<AppState>,
    Json(payload): Json<protocol::LibraryFileBatchActionRequest>,
) -> ApiResult<protocol::LibraryBatchActionResult> {
    let result =
        core_db::manage_library_files(state.pool(), &payload.file_ids, &payload.action).await?;
    state
        .bump_library_revision("library file inventory batch changed")
        .await;
    Ok(Json(result))
}

pub(crate) async fn preview_library_track_merge(
    State(state): State<AppState>,
    Json(payload): Json<TrackMergePreviewRequest>,
) -> ApiResult<protocol::TrackMergePreview> {
    Ok(Json(
        core_db::preview_track_merge(state.pool(), &payload.file_ids, payload.target_track_id)
            .await?,
    ))
}

pub(crate) async fn merge_library_tracks(
    State(state): State<AppState>,
    Json(payload): Json<TrackMergeRequest>,
) -> ApiResult<protocol::TrackMergeResult> {
    let result = core_db::merge_tracks(state.pool(), &payload).await?;
    state
        .bump_library_revision("physical files merged into one release track")
        .await;
    state.emit(
        "library.tracks_merged",
        json!({
            "merge_id": result.merge_id,
            "target_track_id": result.target_track_id,
            "merged_tracks": result.merged_tracks,
        }),
    );
    Ok(Json(result))
}

pub(crate) async fn preview_exact_library_track_merges(
    State(state): State<AppState>,
    Json(payload): Json<AutoTrackMergePreviewRequest>,
) -> ApiResult<protocol::AutoTrackMergePreview> {
    Ok(Json(
        core_db::preview_exact_track_merges(state.pool(), payload.limit).await?,
    ))
}

pub(crate) async fn merge_exact_library_track_groups(
    State(state): State<AppState>,
    Json(payload): Json<AutoTrackMergeRequest>,
) -> ApiResult<protocol::AutoTrackMergeResult> {
    let result = core_db::merge_exact_track_groups(state.pool(), &payload).await?;
    if result.merged_groups > 0 {
        state
            .bump_library_revision("exact duplicate tracks merged")
            .await;
        state.emit(
            "library.tracks_merged",
            json!({
                "action": "auto_merge_exact_duplicates",
                "merged_groups": result.merged_groups,
                "merged_tracks": result.merged_tracks,
                "merge_ids": result.merge_ids,
            }),
        );
    }
    Ok(Json(result))
}

pub(crate) async fn undo_library_track_merge(
    State(state): State<AppState>,
    Path(merge_id): Path<String>,
) -> ApiResult<protocol::TrackMergeResult> {
    let result = core_db::undo_track_merge(state.pool(), &merge_id).await?;
    state
        .bump_library_revision("physical file merge undone")
        .await;
    state.emit(
        "library.tracks_merged",
        json!({
            "merge_id": result.merge_id,
            "target_track_id": result.target_track_id,
            "action": "undone",
        }),
    );
    Ok(Json(result))
}

pub(crate) async fn manage_library_device(
    State(state): State<AppState>,
    Path(device_id): Path<String>,
    Json(payload): Json<protocol::LibraryLifecycleActionRequest>,
) -> ApiResult<protocol::LibraryManagementActionResult> {
    let result = core_db::manage_library_device(state.pool(), &device_id, &payload.action).await?;
    state
        .bump_library_revision("library device lifecycle changed")
        .await;
    Ok(Json(result))
}

pub(crate) async fn manage_library_source(
    State(state): State<AppState>,
    Path(root_id): Path<i64>,
    Json(payload): Json<protocol::LibraryLifecycleActionRequest>,
) -> ApiResult<protocol::LibraryManagementActionResult> {
    let result = core_db::manage_library_source(state.pool(), root_id, &payload.action).await?;
    state
        .bump_library_revision("library source lifecycle changed")
        .await;
    Ok(Json(result))
}
