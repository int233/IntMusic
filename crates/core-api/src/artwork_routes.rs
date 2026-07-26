use super::*;

pub(crate) async fn album_artwork(
    State(state): State<AppState>,
    Path(album_id): Path<i64>,
) -> Result<Response, ApiError> {
    let detail = core_db::album_detail(state.pool(), album_id).await?;
    let Some(track_id) = detail.tracks.first().map(|track| track.id) else {
        return Ok(empty_response(StatusCode::NOT_FOUND));
    };
    artwork_response_for_track(&state, track_id).await
}

pub(crate) async fn track_artwork(
    State(state): State<AppState>,
    Path(track_id): Path<i64>,
) -> Result<Response, ApiError> {
    artwork_response_for_track(&state, track_id).await
}

#[derive(Debug, Deserialize)]
pub(crate) struct ArtistArtworkQuery {
    w: Option<u32>,
    h: Option<u32>,
}

pub(crate) async fn artist_artwork(
    State(state): State<AppState>,
    Path((artist_id, slot)): Path<(i64, String)>,
    Query(query): Query<ArtistArtworkQuery>,
) -> Result<Response, ApiError> {
    let mut source = if let Some(asset_id) = slot
        .strip_prefix("asset-")
        .and_then(|value| value.parse::<i64>().ok())
    {
        let asset = core_db::artist_asset_storage(state.pool(), artist_id, asset_id).await?;
        core_db::ArtistVisualSource {
            visual: protocol::ArtistVisual {
                slot: slot.clone(),
                asset_id: Some(asset_id),
                template: "single".to_string(),
                fit: "cover".to_string(),
                focal_x: 0.5,
                focal_y: 0.5,
                blur: 0.0,
                brightness: 1.0,
                revision: 0,
                regions: Vec::new(),
            },
            assets: vec![asset],
        }
    } else {
        let Some(source) = core_db::artist_visual_source(state.pool(), artist_id, &slot).await?
        else {
            return Ok(empty_response(StatusCode::NOT_FOUND));
        };
        source
    };
    for asset in &mut source.assets {
        let path = FsPath::new(&asset.storage_path);
        if path.is_relative() {
            asset.storage_path = state
                .inner
                .paths
                .data_dir
                .join(path)
                .to_string_lossy()
                .into_owned();
        }
    }

    let default_size = match slot.as_str() {
        "detail_hero" | "home_feature" | "playback_background" => (1600, 560),
        "artist_card" => (768, 960),
        _ => (512, 512),
    };
    let width = query.w.unwrap_or(default_size.0).clamp(32, 2048);
    let height = query.h.unwrap_or(default_size.1).clamp(32, 2048);
    let mut hasher = Sha256::new();
    hasher.update(artist_id.to_le_bytes());
    hasher.update(slot.as_bytes());
    hasher.update(source.visual.revision.to_le_bytes());
    hasher.update(width.to_le_bytes());
    hasher.update(height.to_le_bytes());
    for asset in &source.assets {
        hasher.update(asset.asset.id.to_le_bytes());
        hasher.update(asset.storage_path.as_bytes());
    }
    let cache_key = hex::encode(hasher.finalize());
    let cache_dir = state.inner.paths.cache_dir.join("artist-artwork");
    tokio::fs::create_dir_all(&cache_dir).await?;
    let cache_path = cache_dir.join(format!("{cache_key}.jpg"));
    if tokio::fs::metadata(&cache_path).await.is_err() {
        let source_for_render = source.clone();
        let temporary_path = cache_dir.join(format!(".render-{}.jpg", Uuid::new_v4()));
        let temporary_for_render = temporary_path.clone();
        tokio::task::spawn_blocking(move || {
            render_artist_visual(&source_for_render, width, height, &temporary_for_render)
        })
        .await
        .map_err(anyhow::Error::from)??;
        if tokio::fs::rename(&temporary_path, &cache_path)
            .await
            .is_err()
            && tokio::fs::metadata(&cache_path).await.is_err()
        {
            return Err(anyhow::anyhow!("failed to save rendered artist artwork").into());
        }
    }

    let file = tokio::fs::File::open(&cache_path).await?;
    let len = file.metadata().await?.len();
    let body = Body::from_stream(ReaderStream::new(file));
    let mut response = Response::new(body);
    response
        .headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static("image/jpeg"));
    response.headers_mut().insert(
        header::CONTENT_LENGTH,
        HeaderValue::from_str(&len.to_string()).map_err(anyhow::Error::from)?,
    );
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=31536000, immutable"),
    );
    response.headers_mut().insert(
        header::ETAG,
        HeaderValue::from_str(&format!("\"{cache_key}\"")).map_err(anyhow::Error::from)?,
    );
    Ok(response)
}

pub(crate) fn render_artist_visual(
    source: &core_db::ArtistVisualSource,
    width: u32,
    height: u32,
    output_path: &FsPath,
) -> Result<()> {
    let mut canvas = RgbaImage::new(width, height);
    let regions = &source.visual.regions;
    if regions.is_empty() {
        let asset_id = source
            .visual
            .asset_id
            .or_else(|| source.assets.first().map(|asset| asset.asset.id))
            .context("artist visual has no source asset")?;
        let asset = source
            .assets
            .iter()
            .find(|asset| asset.asset.id == asset_id)
            .context("artist visual source asset is missing")?;
        let image = load_artist_image(&asset.storage_path)?;
        let rendered = crop_and_resize_with_focal(
            &image,
            width,
            height,
            source.visual.focal_x,
            source.visual.focal_y,
            None,
        );
        imageops::overlay(&mut canvas, &rendered.to_rgba8(), 0, 0);
    } else {
        let layout = composition_layout(regions.len(), &source.visual.template);
        for (region, target) in regions.iter().zip(layout) {
            let Some(asset) = source
                .assets
                .iter()
                .find(|asset| asset.asset.id == region.asset_id)
            else {
                continue;
            };
            let target_x = (target.0 * width as f32).round() as u32;
            let target_y = (target.1 * height as f32).round() as u32;
            let target_width = (target.2 * width as f32).round().max(1.0) as u32;
            let target_height = (target.3 * height as f32).round().max(1.0) as u32;
            let image = load_artist_image(&asset.storage_path)?;
            let crop = (
                region.crop_x,
                region.crop_y,
                region.crop_width,
                region.crop_height,
            );
            let rendered = crop_and_resize_with_focal(
                &image,
                target_width,
                target_height,
                region.focal_x,
                region.focal_y,
                Some(crop),
            );
            imageops::overlay(
                &mut canvas,
                &rendered.to_rgba8(),
                i64::from(target_x),
                i64::from(target_y),
            );
        }
    }

    let mut rendered = DynamicImage::ImageRgba8(canvas);
    if source.visual.blur > 0.1 {
        rendered = rendered.blur(source.visual.blur.min(40.0));
    }
    if (source.visual.brightness - 1.0).abs() > 0.01 {
        rendered = rendered.brighten(((source.visual.brightness - 1.0) * 100.0) as i32);
    }
    let rgb = rendered.to_rgb8();
    let file = std::fs::File::create(output_path)?;
    JpegEncoder::new_with_quality(file, 90).encode(
        &rgb,
        width,
        height,
        image::ExtendedColorType::Rgb8,
    )?;
    Ok(())
}

pub(crate) fn load_artist_image(path: &str) -> Result<DynamicImage> {
    image::ImageReader::open(path)?
        .with_guessed_format()?
        .decode()
        .with_context(|| format!("failed to decode artist image {path}"))
}

pub(crate) fn crop_and_resize_with_focal(
    image: &DynamicImage,
    target_width: u32,
    target_height: u32,
    focal_x: f32,
    focal_y: f32,
    normalized_crop: Option<(f32, f32, f32, f32)>,
) -> DynamicImage {
    let (image_width, image_height) = image.dimensions();
    let (mut x, mut y, mut crop_width, mut crop_height) =
        if let Some((x, y, width, height)) = normalized_crop {
            (
                (x.clamp(0.0, 1.0) * image_width as f32).floor() as u32,
                (y.clamp(0.0, 1.0) * image_height as f32).floor() as u32,
                (width.clamp(0.001, 1.0) * image_width as f32).round() as u32,
                (height.clamp(0.001, 1.0) * image_height as f32).round() as u32,
            )
        } else {
            (0, 0, image_width, image_height)
        };
    crop_width = crop_width.min(image_width.saturating_sub(x)).max(1);
    crop_height = crop_height.min(image_height.saturating_sub(y)).max(1);
    let target_ratio = target_width as f32 / target_height as f32;
    let source_ratio = crop_width as f32 / crop_height as f32;
    if source_ratio > target_ratio {
        let wanted_width = (crop_height as f32 * target_ratio).round() as u32;
        let focal_pixel = x as f32 + focal_x.clamp(0.0, 1.0) * crop_width as f32;
        x = (focal_pixel - wanted_width as f32 / 2.0)
            .clamp(x as f32, (x + crop_width - wanted_width) as f32)
            .round() as u32;
        crop_width = wanted_width.max(1);
    } else if source_ratio < target_ratio {
        let wanted_height = (crop_width as f32 / target_ratio).round() as u32;
        let focal_pixel = y as f32 + focal_y.clamp(0.0, 1.0) * crop_height as f32;
        y = (focal_pixel - wanted_height as f32 / 2.0)
            .clamp(y as f32, (y + crop_height - wanted_height) as f32)
            .round() as u32;
        crop_height = wanted_height.max(1);
    }
    image.crop_imm(x, y, crop_width, crop_height).resize_exact(
        target_width,
        target_height,
        FilterType::Lanczos3,
    )
}

pub(crate) fn composition_layout(count: usize, template: &str) -> Vec<(f32, f32, f32, f32)> {
    match (count, template) {
        (1, _) => vec![(0.0, 0.0, 1.0, 1.0)],
        (2, "stacked") => vec![(0.0, 0.0, 1.0, 0.5), (0.0, 0.5, 1.0, 0.5)],
        (2, _) => vec![(0.0, 0.0, 0.5, 1.0), (0.5, 0.0, 0.5, 1.0)],
        (3, _) => vec![
            (0.0, 0.0, 0.66, 1.0),
            (0.66, 0.0, 0.34, 0.5),
            (0.66, 0.5, 0.34, 0.5),
        ],
        (4, _) => vec![
            (0.0, 0.0, 0.5, 0.5),
            (0.5, 0.0, 0.5, 0.5),
            (0.0, 0.5, 0.5, 0.5),
            (0.5, 0.5, 0.5, 0.5),
        ],
        _ => vec![
            (0.0, 0.0, 0.6, 1.0),
            (0.6, 0.0, 0.2, 0.5),
            (0.8, 0.0, 0.2, 0.5),
            (0.6, 0.5, 0.2, 0.5),
            (0.8, 0.5, 0.2, 0.5),
        ]
        .into_iter()
        .take(count.min(5))
        .collect(),
    }
}

pub(crate) async fn artwork_response_for_track(
    state: &AppState,
    track_id: i64,
) -> Result<Response, ApiError> {
    let source_path = PathBuf::from(core_db::track_file_path(state.pool(), track_id).await?);
    let Some(artwork) =
        cached_artwork_for_source(&state.inner.paths.cache_dir, source_path).await?
    else {
        return Ok(empty_response(StatusCode::NOT_FOUND));
    };

    let file = tokio::fs::File::open(&artwork.path)
        .await
        .map_err(anyhow::Error::from)?;
    let body = Body::from_stream(ReaderStream::new(file));
    let mut response = Response::new(body);
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(&artwork.mime_type).map_err(anyhow::Error::from)?,
    );
    response.headers_mut().insert(
        header::CONTENT_LENGTH,
        HeaderValue::from_str(&artwork.len.to_string()).map_err(anyhow::Error::from)?,
    );
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=86400"),
    );
    Ok(response)
}

pub(crate) fn empty_response(status: StatusCode) -> Response {
    let mut response = Response::new(Body::empty());
    *response.status_mut() = status;
    response
}

#[derive(Debug, Clone)]
pub(crate) struct CachedArtwork {
    path: PathBuf,
    mime_type: String,
    len: u64,
}

#[derive(Debug)]
pub(crate) struct ExtractedArtwork {
    bytes: Vec<u8>,
    mime_type: String,
    extension: String,
}

pub(crate) async fn cached_artwork_for_source(
    cache_dir: &FsPath,
    source_path: PathBuf,
) -> Result<Option<CachedArtwork>> {
    let metadata = tokio::fs::metadata(&source_path)
        .await
        .map_err(anyhow::Error::from)?;
    let key = artwork_cache_key(&source_path, &metadata);
    let artwork_dir = cache_dir.join("artwork");
    tokio::fs::create_dir_all(&artwork_dir)
        .await
        .map_err(anyhow::Error::from)?;

    if let Some(cached) = find_cached_artwork(&artwork_dir, &key).await? {
        return Ok(Some(cached));
    }

    let extracted = tokio::task::spawn_blocking(move || extract_embedded_artwork(&source_path))
        .await
        .map_err(anyhow::Error::from)??;
    let Some(extracted) = extracted else {
        return Ok(None);
    };

    let path = artwork_dir.join(format!("{key}.{}", extracted.extension));
    tokio::fs::write(&path, &extracted.bytes)
        .await
        .map_err(anyhow::Error::from)?;
    Ok(Some(CachedArtwork {
        path,
        mime_type: extracted.mime_type,
        len: extracted.bytes.len() as u64,
    }))
}

pub(crate) fn artwork_cache_key(source_path: &FsPath, metadata: &std::fs::Metadata) -> String {
    let modified = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| format!("{}:{}", duration.as_secs(), duration.subsec_nanos()))
        .unwrap_or_default();
    let mut hasher = Sha256::new();
    hasher.update(source_path.to_string_lossy().as_bytes());
    hasher.update(b"|");
    hasher.update(metadata.len().to_string().as_bytes());
    hasher.update(b"|");
    hasher.update(modified.as_bytes());
    hex::encode(hasher.finalize())
}

pub(crate) async fn find_cached_artwork(
    artwork_dir: &FsPath,
    key: &str,
) -> Result<Option<CachedArtwork>> {
    for (extension, mime_type) in [
        ("jpg", "image/jpeg"),
        ("jpeg", "image/jpeg"),
        ("png", "image/png"),
        ("gif", "image/gif"),
        ("bmp", "image/bmp"),
        ("tif", "image/tiff"),
        ("tiff", "image/tiff"),
    ] {
        let path = artwork_dir.join(format!("{key}.{extension}"));
        let Ok(metadata) = tokio::fs::metadata(&path).await else {
            continue;
        };
        if metadata.is_file() {
            return Ok(Some(CachedArtwork {
                path,
                mime_type: mime_type.to_string(),
                len: metadata.len(),
            }));
        }
    }
    Ok(None)
}

pub(crate) fn extract_embedded_artwork(source_path: &FsPath) -> Result<Option<ExtractedArtwork>> {
    let tagged_file = Probe::open(source_path)?.read()?;
    let picture = tagged_file
        .tags()
        .iter()
        .find_map(|tag| tag.get_picture_type(PictureType::CoverFront))
        .or_else(|| {
            tagged_file
                .tags()
                .iter()
                .find_map(|tag| tag.pictures().first())
        });
    let Some(picture) = picture else {
        return Ok(None);
    };
    if picture.data().is_empty() {
        return Ok(None);
    }
    let (mime_type, extension) = picture_mime_and_extension(picture.mime_type(), picture.data());
    Ok(Some(ExtractedArtwork {
        bytes: picture.data().to_vec(),
        mime_type,
        extension,
    }))
}

pub(crate) fn picture_mime_and_extension(
    mime_type: Option<&MimeType>,
    data: &[u8],
) -> (String, String) {
    if let Some(mime_type) = mime_type {
        if let Some(extension) = mime_type.ext() {
            return (mime_type.as_str().to_string(), extension.to_string());
        }
    }
    if data.starts_with(&[0xff, 0xd8, 0xff]) {
        return ("image/jpeg".to_string(), "jpg".to_string());
    }
    if data.starts_with(b"\x89PNG\r\n\x1a\n") {
        return ("image/png".to_string(), "png".to_string());
    }
    if data.starts_with(b"GIF87a") || data.starts_with(b"GIF89a") {
        return ("image/gif".to_string(), "gif".to_string());
    }
    if data.starts_with(b"BM") {
        return ("image/bmp".to_string(), "bmp".to_string());
    }
    ("application/octet-stream".to_string(), "bin".to_string())
}
