use super::*;

pub(crate) async fn start_scan(State(state): State<AppState>) -> ApiResult<serde_json::Value> {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let config = state.config();
    let scanner_config = ScannerConfig {
        extensions: config.library.extensions.clone(),
        artist_separators: config.metadata.artist_separators.clone(),
        genre_separators: config.metadata.genre_separators.clone(),
    };
    let scan_state = state.clone();
    let event_state = state.clone();

    tokio::spawn(async move {
        while let Some(event) = rx.recv().await {
            match event {
                ScannerEvent::Started => event_state.emit("scan.started", json!({})),
                ScannerEvent::Progress(summary) => {
                    event_state.emit("scan.progress", ScanProgressPayload::from(&summary))
                }
                ScannerEvent::Finished(summary) => {
                    event_state.emit("scan.finished", ScanProgressPayload::from(&summary));
                    event_state.bump_library_revision("scan_finished").await;
                }
                ScannerEvent::Problem { path, message } => event_state.emit(
                    "scan.problem_found",
                    json!({ "path": path, "message": message }),
                ),
            }
        }
    });

    tokio::spawn(async move {
        if let Err(error) =
            library_scanner::scan_all_roots(scan_state.pool().clone(), scanner_config, Some(tx))
                .await
        {
            error!(error = %error, "scan failed");
            scan_state.emit("scan.finished", json!({ "error": error.to_string() }));
        }
    });

    Ok(Json(json!({ "status": "started" })))
}

pub(crate) async fn scan_problems(
    State(state): State<AppState>,
    Query(paging): Query<Paging>,
) -> ApiResult<Vec<protocol::ScanProblem>> {
    Ok(Json(
        core_db::scan_problems(state.pool(), paging.limit(), paging.offset()).await?,
    ))
}

pub(crate) async fn list_albums(
    State(state): State<AppState>,
    Query(paging): Query<Paging>,
) -> ApiResult<Vec<protocol::AlbumSummary>> {
    Ok(Json(
        core_db::list_albums(state.pool(), paging.limit(), paging.offset()).await?,
    ))
}

pub(crate) async fn album_detail(
    State(state): State<AppState>,
    Path(album_id): Path<i64>,
) -> ApiResult<protocol::AlbumDetail> {
    let mut detail = core_db::album_detail(state.pool(), album_id).await?;
    apply_favorite_settings_to_tracks(&state.config().favorites, &mut detail.tracks);
    Ok(Json(detail))
}

pub(crate) async fn list_artists(
    State(state): State<AppState>,
    Query(paging): Query<Paging>,
) -> ApiResult<Vec<protocol::ArtistSummary>> {
    Ok(Json(
        core_db::list_artists(state.pool(), paging.limit(), paging.offset()).await?,
    ))
}

pub(crate) async fn artist_detail(
    State(state): State<AppState>,
    Path(artist_id): Path<i64>,
) -> ApiResult<protocol::ArtistDetail> {
    let config = state.config();
    let mut detail = core_db::artist_detail(state.pool(), artist_id).await?;
    apply_favorite_settings_to_tracks(&config.favorites, &mut detail.tracks);
    Ok(Json(detail))
}

pub(crate) async fn update_artist_profile(
    State(state): State<AppState>,
    Path(artist_id): Path<i64>,
    Json(update): Json<UpdateArtistProfile>,
) -> ApiResult<protocol::ArtistDetail> {
    if let Some(mbid) = update
        .musicbrainz_id
        .as_deref()
        .filter(|id| !id.trim().is_empty())
    {
        parse_musicbrainz_artist_id(mbid)?;
    }
    core_db::update_artist_profile(state.pool(), artist_id, &update).await?;
    let mut detail = core_db::artist_detail(state.pool(), artist_id).await?;
    apply_favorite_settings_to_tracks(&state.config().favorites, &mut detail.tracks);
    state.bump_library_revision("artist profile updated").await;
    state.emit(
        "artist.updated",
        json!({"artist_id": artist_id, "kind": "profile"}),
    );
    Ok(Json(detail))
}

pub(crate) async fn list_artist_assets(
    State(state): State<AppState>,
    Path(artist_id): Path<i64>,
) -> ApiResult<Vec<protocol::ArtistAsset>> {
    Ok(Json(
        core_db::list_artist_assets(state.pool(), artist_id).await?,
    ))
}

pub(crate) async fn upload_artist_assets(
    State(state): State<AppState>,
    Path(artist_id): Path<i64>,
    mut multipart: Multipart,
) -> ApiResult<Vec<protocol::ArtistAsset>> {
    let mut uploaded = Vec::new();
    let mut photo_type = "other".to_string();
    while let Some(field) = multipart.next_field().await? {
        if field.name() == Some("photo_type") {
            photo_type = field.text().await?.trim().to_string();
            continue;
        }
        if field.name() != Some("file") {
            continue;
        }
        let original_filename = field
            .file_name()
            .and_then(|name| FsPath::new(name).file_name())
            .and_then(|name| name.to_str())
            .filter(|name| !name.trim().is_empty())
            .unwrap_or("artist-image")
            .to_string();
        let bytes = field.bytes().await?;
        if bytes.is_empty() {
            return Err(anyhow::anyhow!("the uploaded image is empty").into());
        }
        if bytes.len() > 256 * 1024 * 1024 {
            return Err(anyhow::anyhow!("the uploaded image exceeds 256 MiB").into());
        }

        let owned_bytes = bytes.to_vec();
        let (format, width, height) =
            tokio::task::spawn_blocking(move || inspect_artist_image(&owned_bytes))
                .await
                .map_err(anyhow::Error::from)??;
        let mut hasher = Sha256::new();
        hasher.update(&bytes);
        let sha256 = hex::encode(hasher.finalize());
        let extension = artist_image_extension(format);
        let mime_type = format.to_mime_type();
        let storage_dir = state.inner.paths.data_dir.join("artist-media");
        tokio::fs::create_dir_all(&storage_dir).await?;
        let storage_path = storage_dir.join(format!("{sha256}.{extension}"));
        if tokio::fs::metadata(&storage_path).await.is_err() {
            let temporary_path =
                storage_dir.join(format!(".upload-{}.{extension}", Uuid::new_v4()));
            tokio::fs::write(&temporary_path, &bytes).await?;
            tokio::fs::rename(&temporary_path, &storage_path).await?;
        }
        let storage_path_text = format!("artist-media/{sha256}.{extension}");
        let asset = core_db::add_artist_asset(
            state.pool(),
            artist_id,
            core_db::NewArtistAsset {
                sha256: &sha256,
                original_filename: &original_filename,
                storage_path: &storage_path_text,
                mime_type,
                width,
                height,
                byte_size: bytes.len() as u64,
                photo_type: if photo_type.is_empty() {
                    "other"
                } else {
                    &photo_type
                },
            },
        )
        .await?;
        uploaded.push(asset);
    }
    if uploaded.is_empty() {
        return Err(anyhow::anyhow!("no image file was provided").into());
    }

    let visuals = core_db::list_artist_visuals(state.pool(), artist_id).await?;
    let first_asset_id = uploaded[0].id;
    for slot in ["avatar", "detail_hero"] {
        if !visuals.iter().any(|visual| visual.slot == slot) {
            core_db::save_artist_visual(
                state.pool(),
                artist_id,
                slot,
                &UpdateArtistVisual {
                    asset_id: Some(first_asset_id),
                    template: "single".to_string(),
                    fit: "cover".to_string(),
                    focal_x: 0.5,
                    focal_y: 0.5,
                    blur: 0.0,
                    brightness: 1.0,
                    regions: Vec::new(),
                },
            )
            .await?;
        }
    }
    state.bump_library_revision("artist artwork uploaded").await;
    state.emit(
        "artist.asset.ready",
        json!({
            "artist_id": artist_id,
            "asset_ids": uploaded.iter().map(|asset| asset.id).collect::<Vec<_>>()
        }),
    );
    Ok(Json(uploaded))
}

pub(crate) fn inspect_artist_image(bytes: &[u8]) -> Result<(ImageFormat, u32, u32)> {
    let format = image::guess_format(bytes).context("unsupported or invalid image format")?;
    let reader = image::ImageReader::with_format(Cursor::new(bytes), format);
    let (width, height) = reader
        .into_dimensions()
        .context("failed to read image dimensions")?;
    anyhow::ensure!(width > 0 && height > 0, "image dimensions are invalid");
    anyhow::ensure!(
        u64::from(width) * u64::from(height) <= 250_000_000,
        "decoded image exceeds the 250 megapixel safety limit"
    );
    image::load_from_memory_with_format(bytes, format).context("failed to decode image")?;
    Ok((format, width, height))
}

pub(crate) fn artist_image_extension(format: ImageFormat) -> &'static str {
    match format {
        ImageFormat::Jpeg => "jpg",
        ImageFormat::Png => "png",
        ImageFormat::WebP => "webp",
        ImageFormat::Gif => "gif",
        ImageFormat::Bmp => "bmp",
        ImageFormat::Tiff => "tiff",
        ImageFormat::Avif => "avif",
        ImageFormat::Ico => "ico",
        ImageFormat::Pnm => "pnm",
        ImageFormat::Tga => "tga",
        ImageFormat::Qoi => "qoi",
        _ => "img",
    }
}

pub(crate) async fn update_artist_asset(
    State(state): State<AppState>,
    Path((artist_id, asset_id)): Path<(i64, i64)>,
    Json(update): Json<UpdateArtistAsset>,
) -> ApiResult<protocol::ArtistAsset> {
    let asset = core_db::update_artist_asset(state.pool(), artist_id, asset_id, &update).await?;
    state
        .bump_library_revision("artist artwork metadata updated")
        .await;
    state.emit(
        "artist.updated",
        json!({"artist_id": artist_id, "kind": "asset"}),
    );
    Ok(Json(asset))
}

pub(crate) async fn delete_artist_asset(
    State(state): State<AppState>,
    Path((artist_id, asset_id)): Path<(i64, i64)>,
) -> ApiResult<serde_json::Value> {
    core_db::delete_artist_asset(state.pool(), artist_id, asset_id).await?;
    state.bump_library_revision("artist artwork removed").await;
    state.emit(
        "artist.visual.updated",
        json!({"artist_id": artist_id, "removed_asset_id": asset_id}),
    );
    Ok(Json(json!({"deleted": true})))
}

pub(crate) async fn update_artist_visual(
    State(state): State<AppState>,
    Path((artist_id, slot)): Path<(i64, String)>,
    Json(update): Json<UpdateArtistVisual>,
) -> ApiResult<protocol::ArtistVisual> {
    let visual = core_db::save_artist_visual(state.pool(), artist_id, &slot, &update).await?;
    state.bump_library_revision("artist visual updated").await;
    state.emit(
        "artist.visual.updated",
        json!({"artist_id": artist_id, "slot": slot, "revision": visual.revision}),
    );
    Ok(Json(visual))
}

#[derive(Debug, Deserialize)]
pub(crate) struct MusicBrainzArtistResponse {
    id: String,
    name: String,
    #[serde(rename = "sort-name")]
    sort_name: Option<String>,
    #[serde(rename = "type")]
    artist_type: Option<String>,
    country: Option<String>,
    disambiguation: Option<String>,
    #[serde(rename = "life-span", default)]
    life_span: MusicBrainzLifeSpan,
    #[serde(default)]
    aliases: Vec<MusicBrainzNamedValue>,
    #[serde(default)]
    genres: Vec<MusicBrainzNamedValue>,
    #[serde(default)]
    relations: Vec<MusicBrainzRelation>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct MusicBrainzLifeSpan {
    begin: Option<String>,
    end: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct MusicBrainzNamedValue {
    name: String,
}

#[derive(Debug, Deserialize)]
pub(crate) struct MusicBrainzRelation {
    #[serde(rename = "type")]
    relation_type: String,
    url: Option<MusicBrainzUrl>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct MusicBrainzUrl {
    resource: String,
}

pub(crate) async fn musicbrainz_artist_preview(
    State(state): State<AppState>,
    Path(_artist_id): Path<i64>,
    Json(request): Json<MusicBrainzArtistPreviewRequest>,
) -> ApiResult<MusicBrainzArtistPreview> {
    let mbid = parse_musicbrainz_artist_id(&request.musicbrainz_id)?;
    {
        let mut last_request = state.inner.musicbrainz_gate.lock().await;
        let elapsed = last_request.elapsed();
        if elapsed < Duration::from_secs(1) {
            tokio::time::sleep(Duration::from_secs(1) - elapsed).await;
        }
        *last_request = tokio::time::Instant::now();
    }
    let url =
        format!("https://musicbrainz.org/ws/2/artist/{mbid}?inc=aliases+genres+url-rels&fmt=json");
    let response = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .user_agent(format!(
            "IntMusic/{} ({})",
            env!("CARGO_PKG_VERSION"),
            env!("CARGO_PKG_REPOSITORY")
        ))
        .build()?
        .get(url)
        .send()
        .await?
        .error_for_status()?
        .json::<MusicBrainzArtistResponse>()
        .await?;
    let mut links = response
        .relations
        .into_iter()
        .filter_map(|relation| {
            if relation.relation_type == "image" {
                return None;
            }
            relation.url.map(|url| protocol::ArtistLink {
                label: relation.relation_type,
                url: url.resource,
            })
        })
        .collect::<Vec<_>>();
    links.sort_by(|left, right| left.url.cmp(&right.url));
    links.dedup_by(|left, right| left.url == right.url);
    Ok(Json(MusicBrainzArtistPreview {
        musicbrainz_id: response.id,
        name: response.name,
        sort_name: response.sort_name,
        artist_type: response.artist_type,
        country: response.country,
        begin_date: response.life_span.begin,
        end_date: response.life_span.end,
        disambiguation: response.disambiguation,
        aliases: response
            .aliases
            .into_iter()
            .map(|alias| alias.name)
            .collect(),
        genres: response
            .genres
            .into_iter()
            .map(|genre| genre.name)
            .collect(),
        links,
    }))
}

pub(crate) fn parse_musicbrainz_artist_id(value: &str) -> Result<Uuid> {
    let trimmed = value.trim().trim_end_matches('/');
    let candidate = trimmed.rsplit('/').next().unwrap_or(trimmed);
    Uuid::parse_str(candidate).context("invalid MusicBrainz artist ID or URL")
}
