use super::*;
use protocol::*;
use serde::Serialize;
use serde_json::Value;

fn catalog(state: &AppState, value: impl Serialize) -> Result<Value> {
    let mut v = serde_json::to_value(value)?;
    v["server_id"] = json!(state.inner.server_id.to_string());
    v["catalog_epoch"] = json!(state.inner.catalog_epoch);
    Ok(v)
}
fn changed(state: &AppState, id: Option<i64>) {
    state.emit("collections.changed",json!({"server_id":state.inner.server_id.to_string(),"catalog_epoch":state.inner.catalog_epoch,"collection_id":id}));
}
pub(crate) async fn list_collections(State(state): State<AppState>) -> ApiResult<Value> {
    Ok(Json(catalog(
        &state,
        json!({"items":core_db::list_collections(state.pool()).await?}),
    )?))
}
pub(crate) async fn collection_schema(State(state): State<AppState>) -> ApiResult<Value> {
    Ok(Json(catalog(&state, core_db::collection_rule_schema())?))
}
pub(crate) async fn collection_settings(State(state): State<AppState>) -> ApiResult<Value> {
    Ok(Json(catalog(
        &state,
        core_db::collection_settings(state.pool()).await?,
    )?))
}
pub(crate) async fn update_collection_settings(
    State(state): State<AppState>,
    Json(update): Json<CollectionSettingsUpdate>,
) -> ApiResult<Value> {
    let value = core_db::update_collection_settings(state.pool(), &update).await?;
    changed(&state, None);
    Ok(Json(catalog(&state, value)?))
}
#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct CollectionPageQuery {
    result_version: Option<String>,
    offset: Option<u32>,
    limit: Option<u32>,
}
pub(crate) async fn get_collection(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Query(q): Query<CollectionPageQuery>,
) -> ApiResult<Value> {
    Ok(Json(catalog(
        &state,
        core_db::collection_page(
            state.pool(),
            id,
            q.result_version.as_deref(),
            q.offset.unwrap_or(0),
            q.limit.unwrap_or(50),
        )
        .await?,
    )?))
}
pub(crate) async fn create_collection(
    State(state): State<AppState>,
    Json(write): Json<CollectionWrite>,
) -> ApiResult<Value> {
    let page = core_db::save_collection(
        state.pool(),
        None,
        &write,
        state.config().favorites.treat_max_rating_as_favorite,
    )
    .await?;
    changed(&state, Some(page.collection.id));
    Ok(Json(catalog(&state, page)?))
}
pub(crate) async fn update_collection(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Json(write): Json<CollectionWrite>,
) -> ApiResult<Value> {
    let page = core_db::save_collection(
        state.pool(),
        Some(id),
        &write,
        state.config().favorites.treat_max_rating_as_favorite,
    )
    .await?;
    changed(&state, Some(id));
    Ok(Json(catalog(&state, page)?))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RevisionQuery {
    expected_revision: u64,
}
pub(crate) async fn delete_collection(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Query(q): Query<RevisionQuery>,
) -> ApiResult<Value> {
    core_db::delete_collection(state.pool(), id, q.expected_revision).await?;
    changed(&state, Some(id));
    Ok(Json(catalog(&state, json!({"deleted":true}))?))
}
pub(crate) async fn preview_collection(
    State(state): State<AppState>,
    Json(def): Json<CollectionDefinition>,
) -> ApiResult<Value> {
    Ok(Json(catalog(
        &state,
        core_db::preview_collection(
            state.pool(),
            &def,
            state.config().favorites.treat_max_rating_as_favorite,
        )
        .await?,
    )?))
}
pub(crate) async fn refresh_collection(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Json(r): Json<CollectionRefreshRequest>,
) -> ApiResult<Value> {
    let page = core_db::refresh_collection(
        state.pool(),
        id,
        &r,
        state.config().favorites.treat_max_rating_as_favorite,
    )
    .await?;
    changed(&state, Some(id));
    Ok(Json(catalog(&state, page)?))
}
pub(crate) async fn reset_collection(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Json(r): Json<RevisionQuery>,
) -> ApiResult<Value> {
    let page = core_db::collection_page(state.pool(), id, None, 0, 1).await?;
    let key = page.collection.system_key.ok_or_else(|| {
        anyhow::anyhow!(core_db::CollectionError {
            code: "collection_invalid",
            message: "用户集合没有系统默认规则".into(),
            current_revision: None
        })
    })?;
    let write = CollectionWrite {
        expected_revision: Some(r.expected_revision),
        definition: core_db::default_collection(&key)?,
    };
    let page = core_db::save_collection(
        state.pool(),
        Some(id),
        &write,
        state.config().favorites.treat_max_rating_as_favorite,
    )
    .await?;
    changed(&state, Some(id));
    Ok(Json(catalog(&state, page)?))
}
pub(crate) async fn collection_play(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Json(r): Json<CollectionPlayRequest>,
) -> ApiResult<Value> {
    Ok(Json(catalog(
        &state,
        core_db::collection_play_plan(
            state.pool(),
            id,
            &r,
            state.config().favorites.treat_max_rating_as_favorite,
        )
        .await?,
    )?))
}
#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct EntityQuery {
    q: Option<String>,
    ids: Option<String>,
    offset: Option<u32>,
    limit: Option<u32>,
}
pub(crate) async fn collection_entities(
    State(state): State<AppState>,
    Path(kind): Path<EntityType>,
    Query(q): Query<EntityQuery>,
) -> ApiResult<Value> {
    let invalid = || {
        anyhow::anyhow!(core_db::CollectionError {
            code: "collection_invalid",
            message: "成员标识须为正整数，每次最多 200 项".into(),
            current_revision: None
        })
    };
    let ids = q
        .ids
        .as_deref()
        .map(|value| {
            value
                .split(',')
                .map(|v| v.parse::<i64>().ok().filter(|v| *v > 0).ok_or_else(invalid))
                .collect::<Result<Vec<_>>>()
        })
        .transpose()?;
    if ids.as_ref().is_some_and(|v| v.len() > 200) {
        return Err(invalid().into());
    }
    Ok(Json(catalog(
        &state,
        core_db::browse_collection_entities(
            state.pool(),
            kind,
            q.q.as_deref().unwrap_or(""),
            ids.as_deref(),
            q.offset.unwrap_or(0),
            q.limit.unwrap_or(50),
            state.config().favorites.treat_max_rating_as_favorite,
        )
        .await?,
    )?))
}

pub(crate) async fn get_home_layout(State(state): State<AppState>) -> ApiResult<Value> {
    Ok(Json(catalog(
        &state,
        core_db::home_layout(state.pool()).await?,
    )?))
}
pub(crate) async fn update_home_layout(
    State(state): State<AppState>,
    Json(update): Json<HomeLayoutUpdate>,
) -> ApiResult<Value> {
    let layout = core_db::save_home_layout(state.pool(), &update).await?;
    changed(&state, None);
    Ok(Json(catalog(&state, layout)?))
}
pub(crate) async fn search(
    State(state): State<AppState>,
    Query(q): Query<SearchParams>,
) -> ApiResult<SearchResponse> {
    let limit = q.limit.unwrap_or(25).clamp(1, 100);
    let search = q.q.to_lowercase();
    let collections = core_db::list_collections(state.pool())
        .await?
        .into_iter()
        .filter(|c| {
            c.system_key.is_none()
                && (c.name.to_lowercase().contains(&search)
                    || c.description.to_lowercase().contains(&search))
        })
        .take(limit as usize)
        .collect();
    let mut tracks = core_db::search_tracks(state.pool(), &q.q, limit).await?;
    apply_favorite_settings_to_tracks(&state.config().favorites, &mut tracks);
    Ok(Json(SearchResponse {
        query: q.q.clone(),
        tracks,
        albums: core_db::search_albums(state.pool(), &q.q, limit).await?,
        artists: core_db::search_artists(state.pool(), &q.q, limit).await?,
        collections,
    }))
}
pub(crate) fn start_collection_worker(state: AppState) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(2));
        loop {
            interval.tick().await;
            match core_db::refresh_stale_collections(
                state.pool(),
                state.config().favorites.treat_max_rating_as_favorite,
            )
            .await
            {
                Ok(ids) => {
                    for id in ids {
                        changed(&state, Some(id));
                    }
                }
                Err(e) => error!(%e,"collection refresh failed"),
            }
        }
    });
}

pub(crate) async fn get_genre(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> ApiResult<Value> {
    Ok(Json(catalog(
        &state,
        core_db::collection_genre_detail(
            state.pool(),
            id,
            state.config().favorites.treat_max_rating_as_favorite,
        )
        .await?,
    )?))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn collection_routes_enforce_catalog_revision_protection_and_layout_contracts() {
        let (state, dir) = crate::playback_v3_routes::lifecycle_tests::state().await;
        core_db::migrate(state.pool()).await.unwrap();
        core_db::refresh_stale_collections(state.pool(), false)
            .await
            .unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let router = build_router(state.clone());
        let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        let base = format!("http://{addr}/api/v1");
        let client = reqwest::Client::builder().no_proxy().build().unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(
            "x-intmusic-server-id",
            HeaderValue::from_str(&state.inner.server_id.to_string()).unwrap(),
        );
        headers.insert(
            "x-intmusic-catalog-epoch",
            HeaderValue::from_str(&state.inner.catalog_epoch).unwrap(),
        );
        let mut def = core_db::empty_collection(EntityType::Track);
        def.name = "My songs".into();
        def.automatic = Some(CollectionPredicate::All { conditions: vec![] });
        let body = json!({"expected_revision":null,"definition":def});
        assert_eq!(
            client
                .post(format!("{base}/collections"))
                .json(&body)
                .send()
                .await
                .unwrap()
                .status(),
            409
        );
        let created = client
            .post(format!("{base}/collections"))
            .headers(headers.clone())
            .json(&body)
            .send()
            .await
            .unwrap();
        assert_eq!(created.status(), 200);
        let page: Value = created.json().await.unwrap();
        let id = page["collection"]["id"].as_i64().unwrap();
        assert!(page["result_total"].as_u64().unwrap() > 0);
        assert_eq!(page["server_id"], state.inner.server_id.to_string());
        let invalid = client
            .patch(format!("{base}/collections/{id}"))
            .headers(headers.clone())
            .json(&json!({"expected_revision":0,"definition":def}))
            .send()
            .await
            .unwrap();
        assert_eq!(invalid.status(), 409);
        assert_eq!(
            client
                .get(format!("{base}/collections/{id}?offset=1"))
                .send()
                .await
                .unwrap()
                .status(),
            422
        );
        assert_eq!(
            client
                .get(format!("{base}/collections/{id}?result_version=missing"))
                .send()
                .await
                .unwrap()
                .status(),
            410
        );
        let system = core_db::list_collections(state.pool())
            .await
            .unwrap()
            .into_iter()
            .find(|c| c.system_key.is_some())
            .unwrap();
        assert_eq!(
            client
                .delete(format!(
                    "{base}/collections/{}?expected_revision=1",
                    system.id
                ))
                .headers(headers.clone())
                .send()
                .await
                .unwrap()
                .status(),
            403
        );
        assert_eq!(
            client
                .patch(format!("{base}/home-layout"))
                .json(&json!({"expected_revision":1,"sections":[]}))
                .send()
                .await
                .unwrap()
                .status(),
            409
        );
        assert_eq!(
            client
                .patch(format!("{base}/home-layout"))
                .headers(headers.clone())
                .json(&json!({"expected_revision":1,"sections":[]}))
                .send()
                .await
                .unwrap()
                .status(),
            200
        );
        assert_eq!(
            client
                .get(format!("{base}/playlists"))
                .send()
                .await
                .unwrap()
                .status(),
            404
        );
        let plan: Value = client
            .post(format!("{base}/collections/{id}/play"))
            .headers(headers)
            .json(&json!({"result_version":page["result_version"],"entity_ids":null}))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(
            plan["tracks"].as_array().unwrap().len(),
            page["result_total"].as_u64().unwrap() as usize
        );
        server.abort();
        state.pool().close().await;
        drop(state);
        let _ = tokio::fs::remove_dir_all(dir).await;
    }
}
