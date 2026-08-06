use super::*;

pub async fn list_albums(pool: &DbPool, limit: u32, offset: u32) -> Result<Vec<AlbumSummary>> {
    let rows = sqlx::query(
        r#"
        SELECT canonical.id,
               COALESCE(NULLIF(profile.title, ''), canonical.title) AS title,
               COALESCE(NULLIF(profile.album_artist_display, ''),
                        canonical.album_artist_display) AS album_artist_display,
               COALESCE(NULLIF(profile.date, ''), canonical.date,
                        MAX(member_album.date)) AS date,
               COALESCE(profile.year, canonical.year, MAX(member_album.year)) AS year,
               COALESCE(profile.total_discs, MAX(member_album.total_discs)) AS total_discs,
               COALESCE(canonical.cover_asset_id, MAX(member_album.cover_asset_id)) AS cover_asset_id,
               COUNT(DISTINCT CASE WHEN member.track_id IS NULL THEN COALESCE(
                   'release:' || links.release_track_id,
                   'legacy:' || t.id
               ) END) AS track_count
        FROM album_identity_members identity
        JOIN albums canonical ON canonical.id = identity.canonical_album_id
        LEFT JOIN album_metadata_profiles profile ON profile.album_id = canonical.id
        JOIN albums member_album ON member_album.id = identity.album_id
        JOIN tracks t ON t.album_id = member_album.id
        JOIN active_catalog_tracks active ON active.track_id = t.id
        LEFT JOIN legacy_track_catalog_links links ON links.track_id = t.id
        LEFT JOIN track_merge_members member ON member.track_id = t.id
        GROUP BY canonical.id
        HAVING track_count > 0
        ORDER BY COALESCE(profile.sort_title, profile.title,
                          canonical.sort_title, canonical.title) COLLATE NOCASE
        LIMIT ?1 OFFSET ?2
        "#,
    )
    .bind(limit as i64)
    .bind(offset as i64)
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_album).collect()
}

pub async fn list_artists(pool: &DbPool, limit: u32, offset: u32) -> Result<Vec<ArtistSummary>> {
    let rows = sqlx::query(
        r#"
        SELECT ar.id,
               COALESCE(NULLIF(ap.display_name, ''), ar.name) AS name,
               COALESCE(NULLIF(ap.sort_name, ''), ar.sort_name) AS sort_name,
               COUNT(DISTINCT COALESCE(
                   'recording:' || recording.id,
                   'legacy:' || ta.track_id
               )) AS track_count,
               COUNT(DISTINCT album_identity.canonical_album_id) AS album_count,
               COALESCE((SELECT MAX(av.revision)
                         FROM artist_visuals av
                         WHERE av.artist_id = ar.id), 0) AS artwork_revision,
               EXISTS(SELECT 1
                      FROM artist_assets ai
                      WHERE ai.artist_id = ar.id AND ai.deleted_at IS NULL) AS has_artwork
        FROM artists ar
        LEFT JOIN artist_profiles ap ON ap.artist_id = ar.id
        LEFT JOIN track_artists ta ON ta.artist_id = ar.id
        LEFT JOIN legacy_track_catalog_links links ON links.track_id = ta.track_id
        LEFT JOIN release_tracks release_track ON release_track.id = links.release_track_id
        LEFT JOIN catalog_recordings recording ON recording.id = release_track.recording_id
        LEFT JOIN album_artists aa ON aa.artist_id = ar.id
        LEFT JOIN album_identity_members album_identity ON album_identity.album_id = aa.album_id
        GROUP BY ar.id
        ORDER BY COALESCE(NULLIF(ap.sort_name, ''), ar.sort_name,
                          NULLIF(ap.display_name, ''), ar.name) COLLATE NOCASE
        LIMIT ?1 OFFSET ?2
        "#,
    )
    .bind(limit as i64)
    .bind(offset as i64)
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_artist).collect()
}

pub async fn artist_detail(pool: &DbPool, artist_id: i64) -> Result<ArtistDetail> {
    let artist_row = sqlx::query(
        r#"
        SELECT ar.id,
               COALESCE(NULLIF(ap.display_name, ''), ar.name) AS name,
               COALESCE(NULLIF(ap.sort_name, ''), ar.sort_name) AS sort_name,
               COUNT(DISTINCT COALESCE(
                   'recording:' || recording.id,
                   'legacy:' || ta.track_id
               )) AS track_count,
               COUNT(DISTINCT album_identity.canonical_album_id) AS album_count,
               COALESCE((SELECT MAX(av.revision)
                         FROM artist_visuals av
                         WHERE av.artist_id = ar.id), 0) AS artwork_revision,
               EXISTS(SELECT 1
                      FROM artist_assets ai
                      WHERE ai.artist_id = ar.id AND ai.deleted_at IS NULL) AS has_artwork
        FROM artists ar
        LEFT JOIN artist_profiles ap ON ap.artist_id = ar.id
        LEFT JOIN track_artists ta ON ta.artist_id = ar.id
        LEFT JOIN legacy_track_catalog_links links ON links.track_id = ta.track_id
        LEFT JOIN release_tracks release_track ON release_track.id = links.release_track_id
        LEFT JOIN catalog_recordings recording ON recording.id = release_track.recording_id
        LEFT JOIN album_artists aa ON aa.artist_id = ar.id
        LEFT JOIN album_identity_members album_identity ON album_identity.album_id = aa.album_id
        WHERE ar.id = ?1
        GROUP BY ar.id
        "#,
    )
    .bind(artist_id)
    .fetch_one(pool)
    .await?;

    let album_rows = sqlx::query(
        r#"
        SELECT canonical.id,
               COALESCE(NULLIF(profile.title, ''), canonical.title) AS title,
               COALESCE(NULLIF(profile.album_artist_display, ''),
                        canonical.album_artist_display) AS album_artist_display,
               COALESCE(NULLIF(profile.date, ''), canonical.date,
                        MAX(member_album.date)) AS date,
               COALESCE(profile.year, canonical.year, MAX(member_album.year)) AS year,
               COALESCE(profile.total_discs, MAX(member_album.total_discs)) AS total_discs,
               COALESCE(canonical.cover_asset_id, MAX(member_album.cover_asset_id)) AS cover_asset_id,
               COUNT(DISTINCT CASE WHEN member.track_id IS NULL THEN COALESCE(
                   'release:' || links.release_track_id,
                   'legacy:' || t.id
               ) END) AS track_count
        FROM album_identity_members identity
        JOIN albums canonical ON canonical.id = identity.canonical_album_id
        LEFT JOIN album_metadata_profiles profile ON profile.album_id = canonical.id
        JOIN albums member_album ON member_album.id = identity.album_id
        JOIN tracks t ON t.album_id = member_album.id
        JOIN active_catalog_tracks active ON active.track_id = t.id
        LEFT JOIN legacy_track_catalog_links links ON links.track_id = t.id
        LEFT JOIN track_merge_members member ON member.track_id = t.id
        LEFT JOIN album_artists aa ON aa.album_id = member_album.id
        LEFT JOIN track_artists ta ON ta.track_id = t.id
        WHERE aa.artist_id = ?1 OR ta.artist_id = ?1
        GROUP BY canonical.id
        HAVING track_count > 0
        ORDER BY COALESCE(profile.year, canonical.year, 0) DESC,
                 COALESCE(profile.title, canonical.title) COLLATE NOCASE
        "#,
    )
    .bind(artist_id)
    .fetch_all(pool)
    .await?;

    let track_rows = sqlx::query(
        track_select_sql(
            r#"
            WHERE EXISTS (
                SELECT 1
                FROM track_artists ta2
                WHERE ta2.track_id = t.id AND ta2.artist_id = ?1
            )
              AND NOT EXISTS (
                SELECT 1 FROM track_merge_members member
                WHERE member.track_id = t.id
              )
              AND EXISTS (
                SELECT 1 FROM active_catalog_tracks active
                WHERE active.track_id = t.id
              )
              AND (
                NOT EXISTS (
                  SELECT 1 FROM legacy_track_catalog_links missing_link
                  WHERE missing_link.track_id = t.id
                )
                OR t.id = (
                SELECT MIN(candidate.track_id)
                FROM legacy_track_catalog_links candidate
                JOIN release_tracks candidate_release
                  ON candidate_release.id = candidate.release_track_id
                LEFT JOIN track_merge_members member
                  ON member.track_id = candidate.track_id
                WHERE member.track_id IS NULL
                  AND candidate_release.recording_id = (
                    SELECT current_release.recording_id
                    FROM legacy_track_catalog_links current_link
                    JOIN release_tracks current_release
                      ON current_release.id = current_link.release_track_id
                    WHERE current_link.track_id = t.id
                  )
                )
              )
            GROUP BY t.id
            ORDER BY t.title COLLATE NOCASE
            "#,
        )
        .as_str(),
    )
    .bind(artist_id)
    .fetch_all(pool)
    .await?;

    Ok(ArtistDetail {
        artist: row_to_artist(artist_row)?,
        profile: artist_profile(pool, artist_id).await?,
        assets: list_artist_assets(pool, artist_id).await?,
        visuals: list_artist_visuals(pool, artist_id).await?,
        albums: album_rows
            .into_iter()
            .map(row_to_album)
            .collect::<Result<_>>()?,
        tracks: track_rows
            .into_iter()
            .map(row_to_track)
            .collect::<Result<_>>()?,
    })
}

pub async fn artist_profile(pool: &DbPool, artist_id: i64) -> Result<ArtistProfile> {
    let row = sqlx::query(
        r#"
        SELECT display_name, sort_name, musicbrainz_id, artist_type, country,
               begin_date, end_date, disambiguation, biography, aliases_json,
               genres_json, links_json, updated_at
        FROM artist_profiles
        WHERE artist_id = ?1
        "#,
    )
    .bind(artist_id)
    .fetch_optional(pool)
    .await?;
    let Some(row) = row else {
        return Ok(ArtistProfile::default());
    };
    Ok(ArtistProfile {
        display_name: row.try_get("display_name")?,
        sort_name: row.try_get("sort_name")?,
        musicbrainz_id: row.try_get("musicbrainz_id")?,
        artist_type: row.try_get("artist_type")?,
        country: row.try_get("country")?,
        begin_date: row.try_get("begin_date")?,
        end_date: row.try_get("end_date")?,
        disambiguation: row.try_get("disambiguation")?,
        biography: row.try_get("biography")?,
        aliases: serde_json::from_str(&row.try_get::<String, _>("aliases_json")?)
            .unwrap_or_default(),
        genres: serde_json::from_str(&row.try_get::<String, _>("genres_json")?).unwrap_or_default(),
        links: serde_json::from_str(&row.try_get::<String, _>("links_json")?).unwrap_or_default(),
        updated_at: Some(parse_datetime(row.try_get::<String, _>("updated_at")?)?),
    })
}

pub async fn update_artist_profile(
    pool: &DbPool,
    artist_id: i64,
    update: &UpdateArtistProfile,
) -> Result<ArtistProfile> {
    let exists: Option<i64> = sqlx::query_scalar("SELECT id FROM artists WHERE id = ?1")
        .bind(artist_id)
        .fetch_optional(pool)
        .await?;
    anyhow::ensure!(exists.is_some(), "artist {artist_id} was not found");

    let now = Utc::now().to_rfc3339();
    let aliases_json = serde_json::to_string(&update.aliases)?;
    let genres_json = serde_json::to_string(&update.genres)?;
    let links_json = serde_json::to_string(&update.links)?;
    sqlx::query(
        r#"
        INSERT INTO artist_profiles (
            artist_id, display_name, sort_name, musicbrainz_id, artist_type,
            country, begin_date, end_date, disambiguation, biography,
            aliases_json, genres_json, links_json, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?14)
        ON CONFLICT(artist_id) DO UPDATE SET
            display_name = excluded.display_name,
            sort_name = excluded.sort_name,
            musicbrainz_id = excluded.musicbrainz_id,
            artist_type = excluded.artist_type,
            country = excluded.country,
            begin_date = excluded.begin_date,
            end_date = excluded.end_date,
            disambiguation = excluded.disambiguation,
            biography = excluded.biography,
            aliases_json = excluded.aliases_json,
            genres_json = excluded.genres_json,
            links_json = excluded.links_json,
            updated_at = excluded.updated_at
        "#,
    )
    .bind(artist_id)
    .bind(trimmed_option(update.display_name.as_deref()))
    .bind(trimmed_option(update.sort_name.as_deref()))
    .bind(trimmed_option(update.musicbrainz_id.as_deref()))
    .bind(trimmed_option(update.artist_type.as_deref()))
    .bind(trimmed_option(update.country.as_deref()))
    .bind(trimmed_option(update.begin_date.as_deref()))
    .bind(trimmed_option(update.end_date.as_deref()))
    .bind(trimmed_option(update.disambiguation.as_deref()))
    .bind(trimmed_option(update.biography.as_deref()))
    .bind(aliases_json)
    .bind(genres_json)
    .bind(links_json)
    .bind(now)
    .execute(pool)
    .await?;
    artist_profile(pool, artist_id).await
}

pub(crate) fn trimmed_option(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

#[derive(Debug, Clone)]
pub struct NewArtistAsset<'a> {
    pub sha256: &'a str,
    pub original_filename: &'a str,
    pub storage_path: &'a str,
    pub mime_type: &'a str,
    pub width: u32,
    pub height: u32,
    pub byte_size: u64,
    pub photo_type: &'a str,
}

#[derive(Debug, Clone)]
pub struct ArtistAssetStorage {
    pub asset: ArtistAsset,
    pub storage_path: String,
}

#[derive(Debug, Clone)]
pub struct ArtistVisualSource {
    pub visual: ArtistVisual,
    pub assets: Vec<ArtistAssetStorage>,
}

pub async fn add_artist_asset(
    pool: &DbPool,
    artist_id: i64,
    asset: NewArtistAsset<'_>,
) -> Result<ArtistAsset> {
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT INTO artist_assets (
            artist_id, sha256, original_filename, storage_path, mime_type,
            width, height, byte_size, photo_type, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10)
        ON CONFLICT(artist_id, sha256) DO UPDATE SET
            original_filename = excluded.original_filename,
            storage_path = excluded.storage_path,
            mime_type = excluded.mime_type,
            width = excluded.width,
            height = excluded.height,
            byte_size = excluded.byte_size,
            deleted_at = NULL,
            updated_at = excluded.updated_at
        "#,
    )
    .bind(artist_id)
    .bind(asset.sha256)
    .bind(asset.original_filename)
    .bind(asset.storage_path)
    .bind(asset.mime_type)
    .bind(i64::from(asset.width))
    .bind(i64::from(asset.height))
    .bind(i64::try_from(asset.byte_size)?)
    .bind(asset.photo_type)
    .bind(now)
    .execute(pool)
    .await?;

    let id: i64 =
        sqlx::query_scalar("SELECT id FROM artist_assets WHERE artist_id = ?1 AND sha256 = ?2")
            .bind(artist_id)
            .bind(asset.sha256)
            .fetch_one(pool)
            .await?;
    artist_asset(pool, artist_id, id).await
}

pub async fn artist_asset(pool: &DbPool, artist_id: i64, id: i64) -> Result<ArtistAsset> {
    let row = sqlx::query(
        r#"
        SELECT id, artist_id, original_filename, mime_type, width, height,
               byte_size, photo_type, sort_order, created_at
        FROM artist_assets
        WHERE artist_id = ?1 AND id = ?2 AND deleted_at IS NULL
        "#,
    )
    .bind(artist_id)
    .bind(id)
    .fetch_one(pool)
    .await?;
    row_to_artist_asset(row)
}

pub async fn artist_asset_storage(
    pool: &DbPool,
    artist_id: i64,
    id: i64,
) -> Result<ArtistAssetStorage> {
    let row = sqlx::query(
        r#"
        SELECT id, artist_id, original_filename, storage_path, mime_type, width,
               height, byte_size, photo_type, sort_order, created_at
        FROM artist_assets
        WHERE artist_id = ?1 AND id = ?2 AND deleted_at IS NULL
        "#,
    )
    .bind(artist_id)
    .bind(id)
    .fetch_one(pool)
    .await?;
    let storage_path: String = row.try_get("storage_path")?;
    Ok(ArtistAssetStorage {
        asset: row_to_artist_asset(row)?,
        storage_path,
    })
}

pub async fn list_artist_assets(pool: &DbPool, artist_id: i64) -> Result<Vec<ArtistAsset>> {
    let rows = sqlx::query(
        r#"
        SELECT id, artist_id, original_filename, mime_type, width, height,
               byte_size, photo_type, sort_order, created_at
        FROM artist_assets
        WHERE artist_id = ?1 AND deleted_at IS NULL
        ORDER BY sort_order, id
        "#,
    )
    .bind(artist_id)
    .fetch_all(pool)
    .await?;
    rows.into_iter().map(row_to_artist_asset).collect()
}

pub async fn update_artist_asset(
    pool: &DbPool,
    artist_id: i64,
    id: i64,
    update: &UpdateArtistAsset,
) -> Result<ArtistAsset> {
    let current = artist_asset(pool, artist_id, id).await?;
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        UPDATE artist_assets
        SET photo_type = ?1, sort_order = ?2, updated_at = ?3
        WHERE artist_id = ?4 AND id = ?5 AND deleted_at IS NULL
        "#,
    )
    .bind(
        update
            .photo_type
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or(&current.photo_type),
    )
    .bind(update.sort_order.unwrap_or(current.sort_order))
    .bind(now)
    .bind(artist_id)
    .bind(id)
    .execute(pool)
    .await?;
    artist_asset(pool, artist_id, id).await
}

pub async fn delete_artist_asset(pool: &DbPool, artist_id: i64, id: i64) -> Result<()> {
    let mut transaction = pool.begin().await?;
    sqlx::query(
        r#"
        UPDATE artist_visuals
        SET asset_id = CASE WHEN asset_id = ?1 THEN NULL ELSE asset_id END,
            revision = revision + 1,
            updated_at = ?2
        WHERE artist_id = ?3 AND (
            asset_id = ?1 OR EXISTS (
                SELECT 1 FROM artist_visual_regions avr
                WHERE avr.artist_id = artist_visuals.artist_id
                  AND avr.slot = artist_visuals.slot
                  AND avr.asset_id = ?1
            )
        )
        "#,
    )
    .bind(id)
    .bind(Utc::now().to_rfc3339())
    .bind(artist_id)
    .execute(&mut *transaction)
    .await?;
    sqlx::query("DELETE FROM artist_visual_regions WHERE artist_id = ?1 AND asset_id = ?2")
        .bind(artist_id)
        .bind(id)
        .execute(&mut *transaction)
        .await?;
    sqlx::query("UPDATE artist_assets SET deleted_at = ?1 WHERE artist_id = ?2 AND id = ?3")
        .bind(Utc::now().to_rfc3339())
        .bind(artist_id)
        .bind(id)
        .execute(&mut *transaction)
        .await?;
    transaction.commit().await?;
    Ok(())
}

pub async fn list_artist_visuals(pool: &DbPool, artist_id: i64) -> Result<Vec<ArtistVisual>> {
    let rows = sqlx::query(
        r#"
        SELECT slot, asset_id, template, fit, focal_x, focal_y, blur,
               brightness, revision
        FROM artist_visuals
        WHERE artist_id = ?1
        ORDER BY slot
        "#,
    )
    .bind(artist_id)
    .fetch_all(pool)
    .await?;
    let mut visuals = Vec::with_capacity(rows.len());
    for row in rows {
        let slot: String = row.try_get("slot")?;
        visuals.push(ArtistVisual {
            asset_id: row.try_get("asset_id")?,
            template: row.try_get("template")?,
            fit: row.try_get("fit")?,
            focal_x: row.try_get::<f64, _>("focal_x")? as f32,
            focal_y: row.try_get::<f64, _>("focal_y")? as f32,
            blur: row.try_get::<f64, _>("blur")? as f32,
            brightness: row.try_get::<f64, _>("brightness")? as f32,
            revision: row.try_get("revision")?,
            regions: artist_visual_regions(pool, artist_id, &slot).await?,
            slot,
        });
    }
    Ok(visuals)
}

async fn artist_visual_regions(
    pool: &DbPool,
    artist_id: i64,
    slot: &str,
) -> Result<Vec<ArtistVisualRegion>> {
    let rows = sqlx::query(
        r#"
        SELECT position, asset_id, crop_x, crop_y, crop_width, crop_height,
               focal_x, focal_y
        FROM artist_visual_regions
        WHERE artist_id = ?1 AND slot = ?2
        ORDER BY position
        "#,
    )
    .bind(artist_id)
    .bind(slot)
    .fetch_all(pool)
    .await?;
    rows.into_iter()
        .map(|row| {
            Ok(ArtistVisualRegion {
                position: u8::try_from(row.try_get::<i64, _>("position")?)?,
                asset_id: row.try_get("asset_id")?,
                crop_x: row.try_get::<f64, _>("crop_x")? as f32,
                crop_y: row.try_get::<f64, _>("crop_y")? as f32,
                crop_width: row.try_get::<f64, _>("crop_width")? as f32,
                crop_height: row.try_get::<f64, _>("crop_height")? as f32,
                focal_x: row.try_get::<f64, _>("focal_x")? as f32,
                focal_y: row.try_get::<f64, _>("focal_y")? as f32,
            })
        })
        .collect()
}

pub async fn save_artist_visual(
    pool: &DbPool,
    artist_id: i64,
    slot: &str,
    update: &UpdateArtistVisual,
) -> Result<ArtistVisual> {
    const SLOTS: &[&str] = &[
        "avatar",
        "artist_card",
        "search_list",
        "detail_hero",
        "home_feature",
        "playback_background",
    ];
    anyhow::ensure!(SLOTS.contains(&slot), "unsupported artist visual slot");
    anyhow::ensure!(
        update.regions.len() <= 5,
        "an artist visual supports at most 5 regions"
    );
    for (index, region) in update.regions.iter().enumerate() {
        anyhow::ensure!(
            region.position as usize == index,
            "visual region positions must be contiguous"
        );
        anyhow::ensure!(
            region.crop_x >= 0.0
                && region.crop_y >= 0.0
                && region.crop_width > 0.0
                && region.crop_height > 0.0
                && region.crop_x + region.crop_width <= 1.0001
                && region.crop_y + region.crop_height <= 1.0001,
            "visual region crop is out of range"
        );
    }

    let mut transaction = pool.begin().await?;
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        INSERT INTO artist_visuals (
            artist_id, slot, asset_id, template, fit, focal_x, focal_y,
            blur, brightness, revision, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 1, ?10)
        ON CONFLICT(artist_id, slot) DO UPDATE SET
            asset_id = excluded.asset_id,
            template = excluded.template,
            fit = excluded.fit,
            focal_x = excluded.focal_x,
            focal_y = excluded.focal_y,
            blur = excluded.blur,
            brightness = excluded.brightness,
            revision = artist_visuals.revision + 1,
            updated_at = excluded.updated_at
        "#,
    )
    .bind(artist_id)
    .bind(slot)
    .bind(update.asset_id)
    .bind(&update.template)
    .bind(&update.fit)
    .bind(update.focal_x.clamp(0.0, 1.0))
    .bind(update.focal_y.clamp(0.0, 1.0))
    .bind(update.blur.clamp(0.0, 40.0))
    .bind(update.brightness.clamp(0.2, 1.5))
    .bind(now)
    .execute(&mut *transaction)
    .await?;
    sqlx::query("DELETE FROM artist_visual_regions WHERE artist_id = ?1 AND slot = ?2")
        .bind(artist_id)
        .bind(slot)
        .execute(&mut *transaction)
        .await?;
    for region in &update.regions {
        sqlx::query(
            r#"
            INSERT INTO artist_visual_regions (
                artist_id, slot, position, asset_id, crop_x, crop_y,
                crop_width, crop_height, focal_x, focal_y
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            "#,
        )
        .bind(artist_id)
        .bind(slot)
        .bind(i64::from(region.position))
        .bind(region.asset_id)
        .bind(region.crop_x)
        .bind(region.crop_y)
        .bind(region.crop_width)
        .bind(region.crop_height)
        .bind(region.focal_x)
        .bind(region.focal_y)
        .execute(&mut *transaction)
        .await?;
    }
    transaction.commit().await?;
    list_artist_visuals(pool, artist_id)
        .await?
        .into_iter()
        .find(|visual| visual.slot == slot)
        .context("saved artist visual was not found")
}

pub async fn artist_visual_source(
    pool: &DbPool,
    artist_id: i64,
    slot: &str,
) -> Result<Option<ArtistVisualSource>> {
    let visual = list_artist_visuals(pool, artist_id)
        .await?
        .into_iter()
        .find(|visual| visual.slot == slot);
    let visual = match visual {
        Some(visual) if visual.asset_id.is_some() || !visual.regions.is_empty() => visual,
        _ => {
            let preferred_types: &[&str] = match slot {
                "detail_hero" | "home_feature" | "playback_background" => {
                    &["background", "landscape", "live", "portrait", "other"]
                }
                _ => &["portrait", "headshot", "other", "background"],
            };
            let mut selected = None;
            for photo_type in preferred_types {
                selected = sqlx::query_scalar::<_, i64>(
                    r#"
                    SELECT id FROM artist_assets
                    WHERE artist_id = ?1 AND deleted_at IS NULL AND photo_type = ?2
                    ORDER BY sort_order, id LIMIT 1
                    "#,
                )
                .bind(artist_id)
                .bind(photo_type)
                .fetch_optional(pool)
                .await?;
                if selected.is_some() {
                    break;
                }
            }
            if selected.is_none() {
                selected = sqlx::query_scalar(
                    r#"
                    SELECT id FROM artist_assets
                    WHERE artist_id = ?1 AND deleted_at IS NULL
                    ORDER BY sort_order, id LIMIT 1
                    "#,
                )
                .bind(artist_id)
                .fetch_optional(pool)
                .await?;
            }
            let Some(asset_id) = selected else {
                return Ok(None);
            };
            ArtistVisual {
                slot: slot.to_string(),
                asset_id: Some(asset_id),
                template: "single".to_string(),
                fit: "cover".to_string(),
                focal_x: 0.5,
                focal_y: 0.5,
                blur: 0.0,
                brightness: 1.0,
                revision: 0,
                regions: Vec::new(),
            }
        }
    };

    let mut asset_ids = visual
        .regions
        .iter()
        .map(|region| region.asset_id)
        .collect::<Vec<_>>();
    if let Some(id) = visual.asset_id {
        asset_ids.push(id);
    }
    asset_ids.sort_unstable();
    asset_ids.dedup();
    let mut assets = Vec::with_capacity(asset_ids.len());
    for id in asset_ids {
        let row = sqlx::query(
            r#"
            SELECT id, artist_id, original_filename, storage_path, mime_type,
                   width, height, byte_size, photo_type, sort_order, created_at
            FROM artist_assets
            WHERE artist_id = ?1 AND id = ?2 AND deleted_at IS NULL
            "#,
        )
        .bind(artist_id)
        .bind(id)
        .fetch_optional(pool)
        .await?;
        if let Some(row) = row {
            let storage_path: String = row.try_get("storage_path")?;
            assets.push(ArtistAssetStorage {
                asset: row_to_artist_asset(row)?,
                storage_path,
            });
        }
    }
    if assets.is_empty() {
        return Ok(None);
    }
    Ok(Some(ArtistVisualSource { visual, assets }))
}

fn row_to_artist_asset(row: sqlx::sqlite::SqliteRow) -> Result<ArtistAsset> {
    Ok(ArtistAsset {
        id: row.try_get("id")?,
        artist_id: row.try_get("artist_id")?,
        original_filename: row.try_get("original_filename")?,
        mime_type: row.try_get("mime_type")?,
        width: u32::try_from(row.try_get::<i64, _>("width")?)?,
        height: u32::try_from(row.try_get::<i64, _>("height")?)?,
        byte_size: u64::try_from(row.try_get::<i64, _>("byte_size")?)?,
        photo_type: row.try_get("photo_type")?,
        sort_order: row.try_get("sort_order")?,
        created_at: parse_datetime(row.try_get::<String, _>("created_at")?)?,
    })
}

pub async fn list_tracks(pool: &DbPool, limit: u32, offset: u32) -> Result<Vec<TrackSummary>> {
    let rows = sqlx::query(
        track_select_sql(
            r#"
            WHERE NOT EXISTS (
                SELECT 1 FROM track_merge_members member
                WHERE member.track_id = t.id
            )
              AND EXISTS (
                SELECT 1 FROM active_catalog_tracks active
                WHERE active.track_id = t.id
              )
              AND (
                NOT EXISTS (
                  SELECT 1 FROM legacy_track_catalog_links missing_link
                  WHERE missing_link.track_id = t.id
                )
                OR t.id = (
                SELECT MIN(candidate.track_id)
                FROM legacy_track_catalog_links candidate
                JOIN release_tracks candidate_release
                  ON candidate_release.id = candidate.release_track_id
                LEFT JOIN track_merge_members member
                  ON member.track_id = candidate.track_id
                WHERE member.track_id IS NULL
                  AND candidate_release.recording_id = (
                    SELECT current_release.recording_id
                    FROM legacy_track_catalog_links current_link
                    JOIN release_tracks current_release
                      ON current_release.id = current_link.release_track_id
                    WHERE current_link.track_id = t.id
                  )
                )
              )
            GROUP BY t.id
            ORDER BY t.id
            LIMIT ?1 OFFSET ?2
            "#,
        )
        .as_str(),
    )
    .bind(limit as i64)
    .bind(offset as i64)
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_track).collect()
}
