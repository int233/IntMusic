use super::*;

pub async fn canonical_album_id(pool: &DbPool, album_id: i64) -> Result<i64> {
    sqlx::query_scalar("SELECT canonical_album_id FROM album_identity_members WHERE album_id = ?1")
        .bind(album_id)
        .fetch_optional(pool)
        .await?
        .context("album not found")
}

pub async fn album_metadata_profile(pool: &DbPool, album_id: i64) -> Result<AlbumMetadataProfile> {
    let album_id = canonical_album_id(pool, album_id).await?;
    let row = sqlx::query(
        r#"
        SELECT
            COALESCE(NULLIF(profile.title, ''), album.title) AS title,
            COALESCE(NULLIF(profile.sort_title, ''), album.sort_title) AS sort_title,
            profile.subtitle,
            profile.release_type,
            profile.edition_title,
            profile.release_status,
            COALESCE(NULLIF(profile.date, ''), album.date) AS date,
            COALESCE(NULLIF(profile.original_date, ''), album.original_date) AS original_date,
            COALESCE(profile.year, album.year) AS year,
            COALESCE(profile.total_discs, album.total_discs) AS total_discs,
            profile.country,
            profile.language,
            profile.media_format,
            profile.packaging,
            profile.barcode,
            profile.catalog_numbers_json,
            profile.labels_json,
            profile.publishers_json,
            profile.genres_json,
            profile.styles_json,
            profile.moods_json,
            profile.copyright,
            profile.phonographic_copyright,
            profile.notes,
            COALESCE(
                NULLIF(profile.album_artist_display, ''),
                album.album_artist_display
            ) AS album_artist_display
        FROM albums album
        LEFT JOIN album_metadata_profiles profile ON profile.album_id = album.id
        WHERE album.id = ?1
        "#,
    )
    .bind(album_id)
    .fetch_one(pool)
    .await?;
    Ok(AlbumMetadataProfile {
        title: row.try_get("title")?,
        sort_title: row.try_get("sort_title")?,
        subtitle: row.try_get("subtitle")?,
        release_type: row.try_get("release_type")?,
        edition_title: row.try_get("edition_title")?,
        release_status: row.try_get("release_status")?,
        date: row.try_get("date")?,
        original_date: row.try_get("original_date")?,
        year: row.try_get("year")?,
        total_discs: row.try_get("total_discs")?,
        country: row.try_get("country")?,
        language: row.try_get("language")?,
        media_format: row.try_get("media_format")?,
        packaging: row.try_get("packaging")?,
        barcode: row.try_get("barcode")?,
        catalog_numbers: json_string_list(row.try_get("catalog_numbers_json")?)?,
        labels: json_string_list(row.try_get("labels_json")?)?,
        publishers: json_string_list(row.try_get("publishers_json")?)?,
        genres: json_string_list(row.try_get("genres_json")?)?,
        styles: json_string_list(row.try_get("styles_json")?)?,
        moods: json_string_list(row.try_get("moods_json")?)?,
        copyright: row.try_get("copyright")?,
        phonographic_copyright: row.try_get("phonographic_copyright")?,
        notes: row.try_get("notes")?,
        album_artist_display: row.try_get("album_artist_display")?,
    })
}

pub async fn album_credits(pool: &DbPool, album_id: i64) -> Result<Vec<AlbumCredit>> {
    let album_id = canonical_album_id(pool, album_id).await?;
    let rows = sqlx::query(
        r#"
        SELECT credit.id, credit.artist_id, artist.name AS artist_name,
               credit.display_name, credit.role, credit.position
        FROM album_credits credit
        LEFT JOIN artists artist ON artist.id = credit.artist_id
        WHERE credit.album_id = ?1
        ORDER BY credit.position, credit.id
        "#,
    )
    .bind(album_id)
    .fetch_all(pool)
    .await?;
    if !rows.is_empty() {
        return rows
            .into_iter()
            .map(|row| {
                Ok(AlbumCredit {
                    id: row.try_get("id")?,
                    artist_id: row.try_get("artist_id")?,
                    artist_name: row.try_get("artist_name")?,
                    display_name: row.try_get("display_name")?,
                    role: row.try_get("role")?,
                    position: row.try_get("position")?,
                })
            })
            .collect();
    }

    let rows = sqlx::query(
        r#"
        SELECT DISTINCT artist.id AS artist_id, artist.name, credit.position
        FROM album_identity_members identity
        JOIN album_artists credit ON credit.album_id = identity.album_id
        JOIN artists artist ON artist.id = credit.artist_id
        WHERE identity.canonical_album_id = ?1
        ORDER BY credit.position, artist.name
        "#,
    )
    .bind(album_id)
    .fetch_all(pool)
    .await?;
    rows.into_iter()
        .enumerate()
        .map(|(position, row)| {
            let name: String = row.try_get("name")?;
            Ok(AlbumCredit {
                id: None,
                artist_id: row.try_get("artist_id")?,
                artist_name: Some(name.clone()),
                display_name: name,
                role: "album_artist".to_string(),
                position: position as i64,
            })
        })
        .collect()
}

pub async fn album_edit_snapshot(pool: &DbPool, album_id: i64) -> Result<AlbumEditSnapshot> {
    let album_id = canonical_album_id(pool, album_id).await?;
    let revision =
        sqlx::query_scalar("SELECT revision FROM album_metadata_profiles WHERE album_id = ?1")
            .bind(album_id)
            .fetch_optional(pool)
            .await?
            .unwrap_or(0);
    let rows = sqlx::query(
        r#"
        SELECT artist.id, COALESCE(NULLIF(profile.display_name, ''), artist.name) AS name
        FROM artists artist
        LEFT JOIN artist_profiles profile ON profile.artist_id = artist.id
        ORDER BY COALESCE(NULLIF(profile.sort_name, ''), artist.sort_name,
                          NULLIF(profile.display_name, ''), artist.name) COLLATE NOCASE
        "#,
    )
    .fetch_all(pool)
    .await?;
    let artist_options = rows
        .into_iter()
        .map(|row| {
            Ok(AlbumArtistReference {
                id: row.try_get("id")?,
                name: row.try_get("name")?,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(AlbumEditSnapshot {
        detail: album_detail(pool, album_id).await?,
        revision,
        artist_options,
    })
}

pub async fn update_album_metadata(
    pool: &DbPool,
    album_id: i64,
    update: &UpdateAlbumMetadata,
) -> Result<AlbumEditSnapshot> {
    let album_id = canonical_album_id(pool, album_id).await?;
    let current_revision: i64 =
        sqlx::query_scalar("SELECT revision FROM album_metadata_profiles WHERE album_id = ?1")
            .bind(album_id)
            .fetch_optional(pool)
            .await?
            .unwrap_or(0);
    if let Some(expected) = update.expected_revision {
        if expected != current_revision {
            bail!(
                "album metadata revision conflict: expected {expected}, current {current_revision}"
            );
        }
    }
    let title =
        trimmed_option(update.profile.title.as_deref()).context("album title cannot be empty")?;
    let credits = normalize_album_credits(pool, &update.credits).await?;
    let album_artist_display = credits
        .iter()
        .filter(|credit| matches!(credit.role.as_str(), "album_artist" | "primary_artist"))
        .map(|credit| credit.display_name.as_str())
        .collect::<Vec<_>>()
        .join(", ");
    let profile = AlbumMetadataProfile {
        title: Some(title),
        album_artist_display: if album_artist_display.is_empty() {
            trimmed_option(update.profile.album_artist_display.as_deref())
        } else {
            Some(album_artist_display)
        },
        ..update.profile.clone()
    };
    let member_ids = sqlx::query_scalar(
        "SELECT album_id FROM album_identity_members WHERE canonical_album_id = ?1",
    )
    .bind(album_id)
    .fetch_all(pool)
    .await?;
    let now = Utc::now().to_rfc3339();
    for member_id in member_ids {
        save_album_profile(pool, member_id, &profile, current_revision + 1, &now).await?;
    }
    sqlx::query("DELETE FROM album_credits WHERE album_id = ?1")
        .bind(album_id)
        .execute(pool)
        .await?;
    for (position, credit) in credits.iter().enumerate() {
        sqlx::query(
            r#"
            INSERT INTO album_credits (
                album_id, artist_id, display_name, role, position, created_at, updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)
            "#,
        )
        .bind(album_id)
        .bind(credit.artist_id)
        .bind(&credit.display_name)
        .bind(&credit.role)
        .bind(position as i64)
        .bind(&now)
        .execute(pool)
        .await?;
    }
    if let Some(propagate) = &update.propagate {
        propagate_album_metadata(pool, album_id, &profile, &credits, propagate, &now).await?;
    }
    album_edit_snapshot(pool, album_id).await
}

pub async fn migrate_album(
    pool: &DbPool,
    source_album_id: i64,
    target_album_id: i64,
) -> Result<AlbumMigrationResult> {
    let source_album_id = canonical_album_id(pool, source_album_id).await?;
    let target_album_id = canonical_album_id(pool, target_album_id).await?;
    if source_album_id == target_album_id {
        bail!("source and target albums are already the same album");
    }
    let moved_track_count: i64 = sqlx::query_scalar(
        r#"
        SELECT COUNT(DISTINCT track.id)
        FROM album_identity_members identity
        JOIN tracks track ON track.album_id = identity.album_id
        JOIN active_catalog_tracks active ON active.track_id = track.id
        WHERE identity.canonical_album_id = ?1
        "#,
    )
    .bind(source_album_id)
    .fetch_one(pool)
    .await?;
    let member_ids: Vec<i64> = sqlx::query_scalar(
        "SELECT album_id FROM album_identity_members WHERE canonical_album_id = ?1",
    )
    .bind(source_album_id)
    .fetch_all(pool)
    .await?;
    let now = Utc::now().to_rfc3339();
    sqlx::query("UPDATE album_manual_merges SET target_album_id = ?1 WHERE target_album_id = ?2")
        .bind(target_album_id)
        .bind(source_album_id)
        .execute(pool)
        .await?;
    for member_id in member_ids {
        if member_id == target_album_id {
            continue;
        }
        sqlx::query(
            r#"
            INSERT INTO album_manual_merges (source_album_id, target_album_id, created_at)
            VALUES (?1, ?2, ?3)
            ON CONFLICT(source_album_id) DO UPDATE SET
                target_album_id = excluded.target_album_id,
                created_at = excluded.created_at
            "#,
        )
        .bind(member_id)
        .bind(target_album_id)
        .bind(&now)
        .execute(pool)
        .await?;
    }
    Ok(AlbumMigrationResult {
        source_album_id,
        target_album_id,
        moved_track_count,
        detail: album_detail(pool, target_album_id).await?,
    })
}

async fn normalize_album_credits(
    pool: &DbPool,
    credits: &[AlbumCredit],
) -> Result<Vec<AlbumCredit>> {
    let mut normalized = Vec::new();
    for credit in credits {
        let display_name = credit.display_name.trim();
        let role = credit.role.trim().to_ascii_lowercase();
        if display_name.is_empty() || role.is_empty() {
            continue;
        }
        let artist_id = match credit.artist_id {
            Some(id) => {
                let exists: bool =
                    sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM artists WHERE id = ?1)")
                        .bind(id)
                        .fetch_one(pool)
                        .await?;
                if !exists {
                    bail!("linked artist {id} does not exist");
                }
                Some(id)
            }
            None => None,
        };
        normalized.push(AlbumCredit {
            id: None,
            artist_id,
            artist_name: credit.artist_name.clone(),
            display_name: display_name.to_string(),
            role,
            position: normalized.len() as i64,
        });
    }
    Ok(normalized)
}

async fn save_album_profile(
    pool: &DbPool,
    album_id: i64,
    profile: &AlbumMetadataProfile,
    revision: i64,
    now: &str,
) -> Result<()> {
    sqlx::query(
        r#"
        INSERT INTO album_metadata_profiles (
            album_id, title, sort_title, subtitle, release_type, edition_title,
            release_status, date, original_date, year, total_discs, country, language,
            media_format, packaging, barcode, catalog_numbers_json, labels_json,
            publishers_json, genres_json, styles_json, moods_json, copyright,
            phonographic_copyright, notes, album_artist_display, revision, updated_at
        ) VALUES (
            ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
            ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28
        )
        ON CONFLICT(album_id) DO UPDATE SET
            title=excluded.title, sort_title=excluded.sort_title,
            subtitle=excluded.subtitle, release_type=excluded.release_type,
            edition_title=excluded.edition_title, release_status=excluded.release_status,
            date=excluded.date, original_date=excluded.original_date, year=excluded.year,
            total_discs=excluded.total_discs,
            country=excluded.country, language=excluded.language,
            media_format=excluded.media_format, packaging=excluded.packaging,
            barcode=excluded.barcode, catalog_numbers_json=excluded.catalog_numbers_json,
            labels_json=excluded.labels_json, publishers_json=excluded.publishers_json,
            genres_json=excluded.genres_json, styles_json=excluded.styles_json,
            moods_json=excluded.moods_json, copyright=excluded.copyright,
            phonographic_copyright=excluded.phonographic_copyright, notes=excluded.notes,
            album_artist_display=excluded.album_artist_display,
            revision=excluded.revision, updated_at=excluded.updated_at
        "#,
    )
    .bind(album_id)
    .bind(trimmed_option(profile.title.as_deref()))
    .bind(trimmed_option(profile.sort_title.as_deref()))
    .bind(trimmed_option(profile.subtitle.as_deref()))
    .bind(trimmed_option(profile.release_type.as_deref()))
    .bind(trimmed_option(profile.edition_title.as_deref()))
    .bind(trimmed_option(profile.release_status.as_deref()))
    .bind(trimmed_option(profile.date.as_deref()))
    .bind(trimmed_option(profile.original_date.as_deref()))
    .bind(profile.year)
    .bind(profile.total_discs)
    .bind(trimmed_option(profile.country.as_deref()))
    .bind(trimmed_option(profile.language.as_deref()))
    .bind(trimmed_option(profile.media_format.as_deref()))
    .bind(trimmed_option(profile.packaging.as_deref()))
    .bind(trimmed_option(profile.barcode.as_deref()))
    .bind(serde_json::to_string(&profile.catalog_numbers)?)
    .bind(serde_json::to_string(&profile.labels)?)
    .bind(serde_json::to_string(&profile.publishers)?)
    .bind(serde_json::to_string(&profile.genres)?)
    .bind(serde_json::to_string(&profile.styles)?)
    .bind(serde_json::to_string(&profile.moods)?)
    .bind(trimmed_option(profile.copyright.as_deref()))
    .bind(trimmed_option(profile.phonographic_copyright.as_deref()))
    .bind(trimmed_option(profile.notes.as_deref()))
    .bind(trimmed_option(profile.album_artist_display.as_deref()))
    .bind(revision)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(())
}

async fn propagate_album_metadata(
    pool: &DbPool,
    album_id: i64,
    profile: &AlbumMetadataProfile,
    credits: &[AlbumCredit],
    propagation: &AlbumTrackPropagation,
    now: &str,
) -> Result<()> {
    let allowed_tracks: HashSet<i64> = sqlx::query_scalar(
        r#"
        SELECT track.id
        FROM album_identity_members identity
        JOIN tracks track ON track.album_id = identity.album_id
        WHERE identity.canonical_album_id = ?1
        "#,
    )
    .bind(album_id)
    .fetch_all(pool)
    .await?
    .into_iter()
    .collect();
    let track_ids: Vec<i64> = propagation
        .track_ids
        .iter()
        .copied()
        .filter(|id| allowed_tracks.contains(id))
        .collect();
    let primary = credit_names(credits, &["primary_artist", "album_artist"]);
    let composers = credit_names(credits, &["composer"]);
    let lyricists = credit_names(credits, &["lyricist"]);
    for track_id in track_ids {
        for field in &propagation.fields {
            let value = match field.as_str() {
                "track_artists" => serde_json::to_value(&primary)?,
                "composers" => serde_json::to_value(&composers)?,
                "lyricists" => serde_json::to_value(&lyricists)?,
                "genres" => serde_json::to_value(&profile.genres)?,
                "date" => serde_json::to_value(&profile.date)?,
                "year" => serde_json::to_value(profile.year)?,
                "disc_total" => serde_json::to_value(profile.total_discs)?,
                "track_total" => serde_json::to_value(allowed_tracks.len() as i64)?,
                _ => continue,
            };
            save_track_override(pool, track_id, field, &value, now).await?;
        }
        rebuild_track_search_row(pool, track_id).await?;
    }
    Ok(())
}

async fn save_track_override(
    pool: &DbPool,
    track_id: i64,
    field: &str,
    value: &Value,
    now: &str,
) -> Result<()> {
    sqlx::query(
        r#"
        INSERT INTO track_metadata_overrides (track_id, field_key, value_json, created_at, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?4)
        ON CONFLICT(track_id, field_key) DO UPDATE SET
            value_json=excluded.value_json, updated_at=excluded.updated_at
        "#,
    )
    .bind(track_id)
    .bind(field)
    .bind(serde_json::to_string(value)?)
    .bind(now)
    .execute(pool)
    .await?;
    sqlx::query(
        r#"
        INSERT INTO track_metadata_state (track_id, revision, updated_at)
        VALUES (?1, 1, ?2)
        ON CONFLICT(track_id) DO UPDATE SET
            revision=track_metadata_state.revision + 1, updated_at=excluded.updated_at
        "#,
    )
    .bind(track_id)
    .bind(now)
    .execute(pool)
    .await?;
    match field {
        "date" => update_track_scalar(pool, track_id, "date", value, now).await?,
        "year" | "disc_total" | "track_total" => {
            update_track_scalar(pool, track_id, field, value, now).await?
        }
        "track_artists" | "composers" | "lyricists" => {
            let role = match field {
                "track_artists" => "primary",
                "composers" => "composer",
                _ => "lyricist",
            };
            let names: Vec<String> = serde_json::from_value(value.clone()).unwrap_or_default();
            sqlx::query("DELETE FROM track_artists WHERE track_id = ?1 AND role = ?2")
                .bind(track_id)
                .bind(role)
                .execute(pool)
                .await?;
            insert_track_artist_role(pool, track_id, role, &names).await?;
        }
        "genres" => {
            let names: Vec<String> = serde_json::from_value(value.clone()).unwrap_or_default();
            sqlx::query("DELETE FROM track_genres WHERE track_id = ?1")
                .bind(track_id)
                .execute(pool)
                .await?;
            for name in names {
                let genre_id = upsert_genre(pool, &name).await?;
                sqlx::query(
                    "INSERT OR IGNORE INTO track_genres (track_id, genre_id) VALUES (?1, ?2)",
                )
                .bind(track_id)
                .bind(genre_id)
                .execute(pool)
                .await?;
            }
        }
        _ => {}
    }
    Ok(())
}

async fn update_track_scalar(
    pool: &DbPool,
    track_id: i64,
    column: &str,
    value: &Value,
    now: &str,
) -> Result<()> {
    if column == "date" {
        sqlx::query("UPDATE tracks SET date = ?1, updated_at = ?2 WHERE id = ?3")
            .bind(value.as_str())
            .bind(now)
            .bind(track_id)
            .execute(pool)
            .await?;
        return Ok(());
    }
    let sql = match column {
        "year" => "UPDATE tracks SET year = ?1, updated_at = ?2 WHERE id = ?3",
        "disc_total" => "UPDATE tracks SET disc_total = ?1, updated_at = ?2 WHERE id = ?3",
        "track_total" => "UPDATE tracks SET track_total = ?1, updated_at = ?2 WHERE id = ?3",
        _ => return Ok(()),
    };
    sqlx::query(sql)
        .bind(value.as_i64())
        .bind(now)
        .bind(track_id)
        .execute(pool)
        .await?;
    Ok(())
}

fn credit_names(credits: &[AlbumCredit], roles: &[&str]) -> Vec<String> {
    credits
        .iter()
        .filter(|credit| roles.contains(&credit.role.as_str()))
        .map(|credit| credit.display_name.clone())
        .collect()
}

fn json_string_list(value: Option<String>) -> Result<Vec<String>> {
    value
        .filter(|value| !value.trim().is_empty())
        .map(|value| serde_json::from_str(&value).context("invalid album metadata list"))
        .transpose()
        .map(|value| value.unwrap_or_default())
}
