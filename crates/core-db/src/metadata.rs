use super::*;

pub(crate) fn client_track_manifest_to_ingest(
    metadata: &ClientTrackManifest,
    relative_path: &str,
) -> TrackIngest {
    let fallback_title = Path::new(relative_path)
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("Unknown track")
        .to_string();
    TrackIngest {
        title: if metadata.title.trim().is_empty() {
            fallback_title
        } else {
            metadata.title.trim().to_string()
        },
        sort_title: metadata.sort_title.clone(),
        subtitle: metadata.subtitle.clone(),
        album: metadata.album.clone(),
        track_artists: metadata.track_artists.clone(),
        album_artists: metadata.album_artists.clone(),
        composers: metadata.composers.clone(),
        lyricists: metadata.lyricists.clone(),
        genres: metadata.genres.clone(),
        disc_number: metadata.disc_number,
        disc_total: metadata.disc_total,
        track_number: metadata.track_number,
        track_total: metadata.track_total,
        duration_ms: metadata.duration_ms,
        date: metadata.date.clone(),
        year: metadata.year,
        bpm: metadata.bpm,
        comment: metadata.comment.clone(),
        lyrics: metadata.lyrics.clone(),
        lyrics_kind: metadata.lyrics_kind.clone(),
        tag_rating: metadata.tag_rating,
        tag_rating_scale: metadata.tag_rating_scale,
    }
}

pub(crate) fn stable_shadow_segment(value: &str) -> String {
    format!("{:x}", Sha384::digest(value.as_bytes()))
}

pub(crate) const TRACK_METADATA_FIELDS: &[(&str, &str, &str, &str)] = &[
    ("title", "Title", "track", "string"),
    ("sort_title", "Sort title", "track", "string"),
    ("subtitle", "Subtitle / version", "track", "string"),
    ("album", "Album", "album", "string"),
    ("track_artists", "Artists", "credits", "string_list"),
    ("album_artists", "Album artists", "album", "string_list"),
    ("composers", "Composers", "credits", "string_list"),
    ("lyricists", "Lyricists", "credits", "string_list"),
    ("genres", "Genres", "classification", "string_list"),
    ("disc_number", "Disc number", "album", "integer"),
    ("disc_total", "Total discs", "album", "integer"),
    ("track_number", "Track number", "track", "integer"),
    ("track_total", "Total tracks", "album", "integer"),
    ("date", "Release date", "album", "string"),
    ("year", "Year", "album", "integer"),
    ("bpm", "BPM", "track", "integer"),
    ("comment", "Comment", "track", "string"),
];

pub(crate) async fn track_id_for_file(pool: &DbPool, file_id: i64) -> Result<Option<i64>> {
    Ok(
        sqlx::query_scalar("SELECT id FROM tracks WHERE file_id = ?1")
            .bind(file_id)
            .fetch_optional(pool)
            .await?,
    )
}

pub(crate) async fn save_track_metadata_source(
    pool: &DbPool,
    file_id: i64,
    track: &TrackIngest,
) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    let data = serde_json::to_string(track)?;
    sqlx::query(
        r#"
        INSERT INTO track_metadata_sources (file_id, source_kind, data_json, captured_at)
        VALUES (?1, 'file', ?2, ?3)
        ON CONFLICT(file_id) DO UPDATE SET
            source_kind = 'file',
            data_json = excluded.data_json,
            captured_at = excluded.captured_at
        "#,
    )
    .bind(file_id)
    .bind(data)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(())
}

pub(crate) async fn load_track_metadata_source(
    pool: &DbPool,
    file_id: i64,
) -> Result<Option<TrackIngest>> {
    let source: Option<String> =
        sqlx::query_scalar("SELECT data_json FROM track_metadata_sources WHERE file_id = ?1")
            .bind(file_id)
            .fetch_optional(pool)
            .await?;
    source
        .map(|source| serde_json::from_str(&source).context("invalid metadata source snapshot"))
        .transpose()
}

pub(crate) async fn load_track_metadata_overrides(
    pool: &DbPool,
    track_id: i64,
) -> Result<HashMap<String, Value>> {
    let rows = sqlx::query(
        "SELECT field_key, value_json FROM track_metadata_overrides WHERE track_id = ?1",
    )
    .bind(track_id)
    .fetch_all(pool)
    .await?;
    let mut values = HashMap::with_capacity(rows.len());
    for row in rows {
        let key: String = row.try_get("field_key")?;
        let value: String = row.try_get("value_json")?;
        values.insert(
            key,
            serde_json::from_str(&value).context("invalid metadata override value")?,
        );
    }
    Ok(values)
}

pub(crate) fn is_supported_metadata_field(key: &str) -> bool {
    TRACK_METADATA_FIELDS
        .iter()
        .any(|(candidate, _, _, _)| candidate == &key)
}

pub(crate) fn normalize_metadata_value(key: &str, value: &Value) -> Result<Value> {
    let value = match key {
        "title" => {
            let title = value
                .as_str()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .context("title cannot be empty")?;
            Value::String(title.to_string())
        }
        "sort_title" | "subtitle" | "album" | "date" | "comment" => match value {
            Value::Null => Value::Null,
            Value::String(value) => {
                let value = value.trim();
                if value.is_empty() {
                    Value::Null
                } else {
                    Value::String(value.to_string())
                }
            }
            _ => bail!("{key} must be a string or null"),
        },
        "track_artists" | "album_artists" | "composers" | "lyricists" | "genres" => {
            let raw_values = match value {
                Value::Array(values) => values
                    .iter()
                    .map(|value| {
                        value
                            .as_str()
                            .map(ToOwned::to_owned)
                            .with_context(|| format!("{key} must contain only strings"))
                    })
                    .collect::<Result<Vec<_>>>()?,
                Value::String(value) => value
                    .split([';', '\n'])
                    .map(ToOwned::to_owned)
                    .collect::<Vec<_>>(),
                Value::Null => Vec::new(),
                _ => bail!("{key} must be a string list"),
            };
            let mut values = Vec::new();
            for value in raw_values {
                let value = value.trim();
                if value.is_empty()
                    || values
                        .iter()
                        .any(|existing: &String| existing.eq_ignore_ascii_case(value))
                {
                    continue;
                }
                values.push(value.to_string());
            }
            serde_json::to_value(values)?
        }
        "disc_number" | "disc_total" | "track_number" | "track_total" | "year" | "bpm" => {
            if value.is_null() {
                Value::Null
            } else {
                let number = value
                    .as_i64()
                    .or_else(|| value.as_str().and_then(|value| value.trim().parse().ok()))
                    .with_context(|| format!("{key} must be an integer or null"))?;
                if number < 0 {
                    bail!("{key} cannot be negative");
                }
                if key == "year" && number > 9999 {
                    bail!("year must be between 0 and 9999");
                }
                if key == "bpm" && number > 999 {
                    bail!("BPM must be between 0 and 999");
                }
                Value::Number(number.into())
            }
        }
        _ => bail!("unsupported metadata field: {key}"),
    };
    Ok(value)
}

pub(crate) fn metadata_field_value(track: &TrackIngest, key: &str) -> Value {
    match key {
        "title" => Value::String(track.title.clone()),
        "sort_title" => serde_json::to_value(&track.sort_title).unwrap_or(Value::Null),
        "subtitle" => serde_json::to_value(&track.subtitle).unwrap_or(Value::Null),
        "album" => serde_json::to_value(&track.album).unwrap_or(Value::Null),
        "track_artists" => serde_json::to_value(&track.track_artists).unwrap_or(Value::Null),
        "album_artists" => serde_json::to_value(&track.album_artists).unwrap_or(Value::Null),
        "composers" => serde_json::to_value(&track.composers).unwrap_or(Value::Null),
        "lyricists" => serde_json::to_value(&track.lyricists).unwrap_or(Value::Null),
        "genres" => serde_json::to_value(&track.genres).unwrap_or(Value::Null),
        "disc_number" => serde_json::to_value(track.disc_number).unwrap_or(Value::Null),
        "disc_total" => serde_json::to_value(track.disc_total).unwrap_or(Value::Null),
        "track_number" => serde_json::to_value(track.track_number).unwrap_or(Value::Null),
        "track_total" => serde_json::to_value(track.track_total).unwrap_or(Value::Null),
        "date" => serde_json::to_value(&track.date).unwrap_or(Value::Null),
        "year" => serde_json::to_value(track.year).unwrap_or(Value::Null),
        "bpm" => serde_json::to_value(track.bpm).unwrap_or(Value::Null),
        "comment" => serde_json::to_value(&track.comment).unwrap_or(Value::Null),
        _ => Value::Null,
    }
}

pub(crate) fn apply_metadata_overrides(
    track: &mut TrackIngest,
    overrides: &HashMap<String, Value>,
) -> Result<()> {
    for (key, value) in overrides {
        let value = normalize_metadata_value(key, value)?;
        match key.as_str() {
            "title" => track.title = value.as_str().unwrap_or_default().to_string(),
            "sort_title" => track.sort_title = value.as_str().map(ToOwned::to_owned),
            "subtitle" => track.subtitle = value.as_str().map(ToOwned::to_owned),
            "album" => track.album = value.as_str().map(ToOwned::to_owned),
            "track_artists" => track.track_artists = serde_json::from_value(value)?,
            "album_artists" => track.album_artists = serde_json::from_value(value)?,
            "composers" => track.composers = serde_json::from_value(value)?,
            "lyricists" => track.lyricists = serde_json::from_value(value)?,
            "genres" => track.genres = serde_json::from_value(value)?,
            "disc_number" => track.disc_number = value.as_i64(),
            "disc_total" => track.disc_total = value.as_i64(),
            "track_number" => track.track_number = value.as_i64(),
            "track_total" => track.track_total = value.as_i64(),
            "date" => track.date = value.as_str().map(ToOwned::to_owned),
            "year" => track.year = value.as_i64(),
            "bpm" => track.bpm = value.as_i64(),
            "comment" => track.comment = value.as_str().map(ToOwned::to_owned),
            _ => bail!("unsupported metadata field: {key}"),
        }
    }
    Ok(())
}
