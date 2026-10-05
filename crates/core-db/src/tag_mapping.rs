use super::*;
use protocol::{TagMappingField, TagMappingRule};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TagSettings {
    pub artist_separators: Vec<String>,
    pub genre_separators: Vec<String>,
    pub tag_mappings: Vec<TagMappingRule>,
}

pub fn validate_tag_mappings(rules: Vec<TagMappingRule>) -> Result<Vec<TagMappingRule>> {
    let mut occupied = HashSet::new();
    let mut result = Vec::new();
    for mut rule in rules {
        rule.source = rule.source.trim().to_string();
        if rule.source.is_empty() {
            bail!("原始标签不能为空");
        }
        if !(1..=5).contains(&rule.targets.len()) {
            bail!("每条规则需要 1～5 个输出标签");
        }
        let mut targets = HashSet::new();
        for target in &mut rule.targets {
            *target = target.trim().to_string();
            if target.is_empty() {
                bail!("输出标签不能为空");
            }
            if !targets.insert(normalize_text(target)) {
                bail!("同一规则的输出标签不能重复");
            }
        }
        let mut fields = HashSet::new();
        rule.fields.retain(|field| fields.insert(*field));
        if rule.fields.is_empty() {
            bail!("请选择规则的应用字段");
        }
        for field in &rule.fields {
            if !occupied.insert((*field, rule.source.clone())) {
                bail!("同一原始标签在同一字段中只能有一条规则：{}", rule.source);
            }
        }
        result.push(rule);
    }
    Ok(result)
}

/// Split delimiters first, then map exact input tags once. Outputs are literal:
/// they are neither split again nor fed into another mapping rule.
pub fn map_tag_values(
    field: TagMappingField,
    values: &[String],
    separators: &[String],
    rules: &[TagMappingRule],
) -> Vec<String> {
    let mut result = Vec::new();
    let mut seen = HashSet::new();
    for value in values {
        let mut parts = vec![value.as_str()];
        for separator in separators.iter().filter(|s| !s.is_empty()) {
            parts = parts
                .into_iter()
                .flat_map(|part| part.split(separator.as_str()))
                .collect();
        }
        for part in parts.into_iter().map(str::trim).filter(|p| !p.is_empty()) {
            let rule = rules
                .iter()
                .find(|rule| rule.fields.contains(&field) && rule.source == part);
            let terms = rule
                .map(|rule| rule.targets.iter().map(String::as_str).collect())
                .unwrap_or_else(|| vec![part]);
            for term in terms {
                if seen.insert(normalize_text(term)) {
                    result.push(term.to_string());
                }
            }
        }
    }
    result
}

pub(crate) fn mapped_track_tags(track: &TrackIngest, settings: &TagSettings) -> TrackIngest {
    let mut result = track.clone();
    for (field, values) in [
        (TagMappingField::Genres, &mut result.genres),
        (TagMappingField::TrackArtists, &mut result.track_artists),
        (TagMappingField::AlbumArtists, &mut result.album_artists),
        (TagMappingField::Composers, &mut result.composers),
        (TagMappingField::Lyricists, &mut result.lyricists),
    ] {
        let separators = if field == TagMappingField::Genres {
            &settings.genre_separators
        } else {
            &settings.artist_separators
        };
        *values = map_tag_values(field, values, separators, &settings.tag_mappings);
    }
    result
}

pub async fn configure_tag_settings(pool: &DbPool, settings: &TagSettings) -> Result<()> {
    let mut settings = settings.clone();
    settings.tag_mappings = validate_tag_mappings(settings.tag_mappings)?;
    sqlx::query("UPDATE metadata_tag_settings SET settings_json = ?1 WHERE id = 1")
        .bind(serde_json::to_string(&settings)?)
        .execute(pool)
        .await?;
    Ok(())
}

pub(crate) async fn catalog_tag_settings(pool: &DbPool) -> Result<TagSettings> {
    let json: String =
        sqlx::query_scalar("SELECT settings_json FROM metadata_tag_settings WHERE id = 1")
            .fetch_one(pool)
            .await?;
    Ok(serde_json::from_str(&json)?)
}

/// Recompute from original metadata plus manual overrides, never yesterday's
/// mapping output. Only multi-value tag fields are replaced; files are untouched.
pub async fn apply_existing_tag_mappings(pool: &DbPool) -> Result<u64> {
    let settings = catalog_tag_settings(pool).await?;
    let rows = sqlx::query("SELECT t.id, t.file_id, f.library_root_id, s.data_json FROM tracks t JOIN files f ON f.id = t.file_id LEFT JOIN track_metadata_sources s ON s.file_id = t.file_id ORDER BY t.id")
        .fetch_all(pool).await?;
    let mut changed = Vec::new();
    for row in rows {
        let id: i64 = row.try_get("id")?;
        let file_id: i64 = row.try_get("file_id")?;
        let root: i64 = row.try_get("library_root_id")?;
        let current = current_track_ingest(pool, id).await?;
        let source: Option<String> = row.try_get("data_json")?;
        let mut original: TrackIngest = match source {
            Some(json) => serde_json::from_str(&json)?,
            None => {
                save_track_metadata_source(pool, file_id, &current).await?;
                current.clone()
            }
        };
        apply_metadata_overrides(
            &mut original,
            &load_track_metadata_overrides(pool, id).await?,
        )?;
        let mut input = current.clone();
        input.genres = original.genres;
        input.track_artists = original.track_artists;
        input.album_artists = original.album_artists;
        input.composers = original.composers;
        input.lyricists = original.lyricists;
        let mapped = mapped_track_tags(&input, &settings);
        // Genre and album-artist identities are unordered, case-insensitive sets.
        let tag_set = |values: &[String]| {
            values
                .iter()
                .map(|s| normalize_text(s))
                .collect::<HashSet<_>>()
        };
        // Compare the effective stored credits, including ingest defaults. Empty
        // credits on untouched rows do not constitute a mapping change.
        let primary = |track: &TrackIngest| {
            if track.track_artists.is_empty() {
                vec!["Unknown Artist".to_string()]
            } else {
                track.track_artists.clone()
            }
        };
        let album_artists = |track: &TrackIngest| {
            if track.album.is_none() {
                Vec::new()
            } else if track.album_artists.is_empty() {
                primary(track)
            } else {
                track.album_artists.clone()
            }
        };
        let same_names = |left: &[String], right: &[String]| {
            left.iter()
                .map(|s| normalize_text(s))
                .eq(right.iter().map(|s| normalize_text(s)))
        };
        let credits_changed = !same_names(&primary(&current), &primary(&mapped))
            || tag_set(&album_artists(&current)) != tag_set(&album_artists(&mapped))
            || !same_names(&current.composers, &mapped.composers)
            || !same_names(&current.lyricists, &mapped.lyricists);
        if !credits_changed && tag_set(&current.genres) == tag_set(&mapped.genres) {
            continue;
        }
        upsert_track(pool, file_id, root, &input, false).await?;
        if credits_changed {
            let file = file_ingest_by_id(pool, file_id).await?;
            ensure_track_media_graph(pool, id, file_id, &file, &input).await?;
        }
        changed.push(id);
    }
    if !changed.is_empty() {
        // One FTS pass, not a full-index scan for every changed song.
        sqlx::query(r#"UPDATE search_fts SET
            artist = (SELECT GROUP_CONCAT(a.name, '; ') FROM track_artists ta JOIN artists a ON a.id = ta.artist_id WHERE ta.track_id = CAST(search_fts.track_id AS INTEGER) AND ta.role = 'primary'),
            genre = (SELECT GROUP_CONCAT(g.name, '; ') FROM track_genres tg JOIN genres g ON g.id = tg.genre_id WHERE tg.track_id = CAST(search_fts.track_id AS INTEGER))
            WHERE CAST(track_id AS INTEGER) IN (SELECT value FROM json_each(?1))"#)
            .bind(serde_json::to_string(&changed)?).execute(pool).await?;
        reconcile_catalog_identity(pool).await?;
    }
    Ok(changed.len() as u64)
}
