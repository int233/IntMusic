use super::*;

pub(crate) async fn settings(State(state): State<AppState>) -> ApiResult<CoreConfig> {
    Ok(Json(state.config()))
}

pub(crate) async fn server_settings(
    State(state): State<AppState>,
) -> ApiResult<core_config::ServerConfig> {
    Ok(Json(state.config().server))
}

pub(crate) async fn update_server_settings(
    State(state): State<AppState>,
    Json(payload): Json<ServerSettingsUpdate>,
) -> ApiResult<core_config::ServerConfig> {
    let mut config = state
        .inner
        .config
        .write()
        .map_err(|_| anyhow::anyhow!("config lock is poisoned"))?;
    if let Some(alias) = payload.alias {
        let cleaned = alias.trim();
        config.server.alias = if cleaned.is_empty() {
            None
        } else {
            Some(cleaned.to_string())
        };
    }
    config.save(&state.inner.paths)?;
    let server = config.server.clone();
    let display_name = core_display_name(&config);
    drop(config);
    state.emit(
        "core.settings_changed",
        json!({ "section": "server", "display_name": display_name }),
    );
    Ok(Json(server))
}

pub(crate) async fn favorite_settings(State(state): State<AppState>) -> ApiResult<FavoritesConfig> {
    Ok(Json(state.config().favorites))
}

pub(crate) async fn metadata_settings(
    State(state): State<AppState>,
) -> ApiResult<core_config::MetadataConfig> {
    Ok(Json(state.config().metadata))
}

pub(crate) async fn update_favorite_settings(
    State(state): State<AppState>,
    Json(payload): Json<FavoriteSettingsUpdate>,
) -> ApiResult<FavoritesConfig> {
    let favorites = {
        let mut config = state
            .inner
            .config
            .write()
            .map_err(|_| anyhow::anyhow!("config lock is poisoned"))?;
        if let Some(value) = payload.treat_max_rating_as_favorite {
            config.favorites.treat_max_rating_as_favorite = value;
        }
        if let Some(value) = payload.write_rating_on_favorite {
            config.favorites.write_rating_on_favorite = value;
        }
        config.save(&state.inner.paths)?;
        config.favorites.clone()
    };
    state
        .bump_library_revision("favorite settings updated")
        .await;
    state.emit("core.settings_changed", json!({ "section": "favorites" }));
    Ok(Json(favorites))
}

pub(crate) async fn update_metadata_settings(
    State(state): State<AppState>,
    Json(payload): Json<MetadataSettingsUpdate>,
) -> ApiResult<core_config::MetadataConfig> {
    let mut config = state
        .inner
        .config
        .write()
        .map_err(|_| anyhow::anyhow!("config lock is poisoned"))?;
    if let Some(values) = payload.artist_separators {
        config.metadata.artist_separators = normalize_separators(values);
    }
    if let Some(values) = payload.genre_separators {
        config.metadata.genre_separators = normalize_separators(values);
    }
    config.save(&state.inner.paths)?;
    let metadata = config.metadata.clone();
    drop(config);
    state.emit("core.settings_changed", json!({ "section": "metadata" }));
    Ok(Json(metadata))
}

pub(crate) fn normalize_separators(values: Vec<String>) -> Vec<String> {
    let mut separators = values
        .into_iter()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>();
    separators.sort();
    separators.dedup();
    if separators.is_empty() {
        vec![",".to_string(), ";".to_string()]
    } else {
        separators
    }
}

pub(crate) async fn diagnostics(State(state): State<AppState>) -> ApiResult<serde_json::Value> {
    Ok(Json(json!({
        "config_file": state.inner.paths.config_file,
        "data_dir": state.inner.paths.data_dir,
        "cache_dir": state.inner.paths.cache_dir,
        "database_file": state.inner.paths.database_file,
        "library_revision": state.inner.library_revision.load(Ordering::SeqCst),
    })))
}

pub(crate) async fn playback_history(
    State(state): State<AppState>,
    Query(query): Query<HistoryQuery>,
) -> ApiResult<Vec<PlaybackEvent>> {
    Ok(Json(
        core_db::list_playback_events(
            state.pool(),
            query.limit(),
            query.offset(),
            query.from,
            query.to,
        )
        .await?,
    ))
}

pub(crate) async fn playback_sessions(
    State(state): State<AppState>,
    Query(query): Query<HistoryQuery>,
) -> ApiResult<Vec<PlaybackSession>> {
    Ok(Json(
        core_db::list_playback_sessions(
            state.pool(),
            query.limit(),
            query.offset(),
            query.from,
            query.to,
        )
        .await?,
    ))
}

pub(crate) async fn playback_stats(
    State(state): State<AppState>,
    Query(query): Query<StatsQuery>,
) -> ApiResult<PlaybackStats> {
    Ok(Json(
        core_db::playback_stats(
            state.pool(),
            query.from,
            query.to,
            query.top_limit.unwrap_or(25),
        )
        .await?,
    ))
}
