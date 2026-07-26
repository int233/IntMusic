use super::*;

pub(crate) async fn search(
    State(state): State<AppState>,
    Query(query): Query<SearchParams>,
) -> ApiResult<SearchResponse> {
    let limit = query.limit.unwrap_or(25).clamp(1, 100);
    let config = state.config();
    let normalized_query = query.q.to_lowercase();
    let playlists =
        core_db::list_playlists(state.pool(), config.favorites.treat_max_rating_as_favorite)
            .await?
            .into_iter()
            .filter(|playlist| {
                playlist.name.to_lowercase().contains(&normalized_query)
                    || playlist.description.as_deref().is_some_and(|description| {
                        description.to_lowercase().contains(&normalized_query)
                    })
            })
            .take(limit as usize)
            .collect();
    let mut response = SearchResponse {
        query: query.q.clone(),
        tracks: core_db::search_tracks(state.pool(), &query.q, limit).await?,
        albums: core_db::search_albums(state.pool(), &query.q, limit).await?,
        artists: core_db::search_artists(state.pool(), &query.q, limit).await?,
        playlists,
    };
    apply_favorite_settings_to_tracks(&config.favorites, &mut response.tracks);
    Ok(Json(response))
}

pub(crate) async fn list_playlists(
    State(state): State<AppState>,
) -> ApiResult<Vec<protocol::PlaylistSummary>> {
    let config = state.config();
    Ok(Json(
        core_db::list_playlists(state.pool(), config.favorites.treat_max_rating_as_favorite)
            .await?,
    ))
}

pub(crate) async fn create_playlist(
    State(state): State<AppState>,
    Json(payload): Json<NewPlaylist>,
) -> ApiResult<PlaylistDetail> {
    let config = state.config();
    let mut detail = core_db::create_playlist(
        state.pool(),
        payload,
        config.favorites.treat_max_rating_as_favorite,
    )
    .await?;
    apply_favorite_settings_to_playlist(&config.favorites, &mut detail);
    state.bump_library_revision("playlist_created").await;
    Ok(Json(detail))
}

pub(crate) async fn get_playlist(
    State(state): State<AppState>,
    Path(playlist_id): Path<i64>,
) -> ApiResult<PlaylistDetail> {
    let config = state.config();
    let mut detail = core_db::playlist_detail(
        state.pool(),
        playlist_id,
        config.favorites.treat_max_rating_as_favorite,
    )
    .await?;
    apply_favorite_settings_to_playlist(&config.favorites, &mut detail);
    Ok(Json(detail))
}

pub(crate) async fn update_playlist(
    State(state): State<AppState>,
    Path(playlist_id): Path<i64>,
    Json(payload): Json<UpdatePlaylist>,
) -> ApiResult<PlaylistDetail> {
    let config = state.config();
    let mut detail = core_db::update_playlist(
        state.pool(),
        playlist_id,
        payload,
        config.favorites.treat_max_rating_as_favorite,
    )
    .await?;
    apply_favorite_settings_to_playlist(&config.favorites, &mut detail);
    state.bump_library_revision("playlist_updated").await;
    Ok(Json(detail))
}

pub(crate) async fn delete_playlist(
    State(state): State<AppState>,
    Path(playlist_id): Path<i64>,
) -> ApiResult<serde_json::Value> {
    core_db::delete_playlist(state.pool(), playlist_id).await?;
    state.bump_library_revision("playlist_deleted").await;
    Ok(Json(json!({ "deleted": true })))
}

pub(crate) async fn add_playlist_track(
    State(state): State<AppState>,
    Path(playlist_id): Path<i64>,
    Json(payload): Json<PlaylistTrackMutation>,
) -> ApiResult<PlaylistDetail> {
    let config = state.config();
    let mut detail = core_db::add_playlist_track(
        state.pool(),
        playlist_id,
        payload,
        config.favorites.treat_max_rating_as_favorite,
    )
    .await?;
    apply_favorite_settings_to_playlist(&config.favorites, &mut detail);
    state.bump_library_revision("playlist_track_added").await;
    Ok(Json(detail))
}

pub(crate) async fn remove_playlist_track(
    State(state): State<AppState>,
    Path((playlist_id, track_id)): Path<(i64, i64)>,
) -> ApiResult<PlaylistDetail> {
    let config = state.config();
    let mut detail = core_db::remove_playlist_track(
        state.pool(),
        playlist_id,
        track_id,
        config.favorites.treat_max_rating_as_favorite,
    )
    .await?;
    apply_favorite_settings_to_playlist(&config.favorites, &mut detail);
    state.bump_library_revision("playlist_track_removed").await;
    Ok(Json(detail))
}

pub(crate) async fn update_track_favorite(
    State(state): State<AppState>,
    Path(track_id): Path<i64>,
    Json(mut payload): Json<TrackFavoriteUpdate>,
) -> ApiResult<protocol::TrackDetail> {
    let config = state.config();
    if payload.is_favorite && config.favorites.write_rating_on_favorite {
        payload.user_rating = payload.user_rating.or(Some(100));
        let path = core_db::track_file_path(state.pool(), track_id).await?;
        let path_for_write = std::path::PathBuf::from(path);
        tokio::task::spawn_blocking(move || {
            library_scanner::write_rating_tag(&path_for_write, 100, 100)
        })
        .await
        .map_err(anyhow::Error::from)??;
        core_db::update_track_tag_rating(state.pool(), track_id, 100, 100).await?;
    }

    let mut detail = core_db::set_track_favorite(state.pool(), track_id, payload).await?;
    apply_favorite_settings_to_track(&config.favorites, &mut detail.track);
    state.bump_library_revision("track_favorite_updated").await;
    Ok(Json(detail))
}
