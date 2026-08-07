use std::collections::{BTreeMap, BTreeSet};

use super::*;

#[derive(Debug, Clone)]
struct MergeIdentity {
    track_id: i64,
    release_track_id: i64,
    recording_id: i64,
    title: String,
    artist_display: Option<String>,
    album_id: Option<i64>,
    album_title: Option<String>,
    disc_number: Option<i64>,
    track_number: Option<i64>,
    duration_ms: Option<i64>,
    recording_kind: String,
    file_count: i64,
    media_variant_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PreviousLink {
    track_id: i64,
    release_track_id: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct InsertedRelation {
    release_track_id: i64,
    media_variant_id: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PreviousMasterRecording {
    master_id: i64,
    recording_id: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PreviousResolution {
    file_id: i64,
    resolution_kind: Option<String>,
    target_track_id: Option<i64>,
    metadata_json: Option<String>,
}

pub async fn preview_track_merge(
    pool: &DbPool,
    file_ids: &[i64],
    requested_target_track_id: Option<i64>,
) -> Result<TrackMergePreview> {
    anyhow::ensure!(
        (2..=200).contains(&file_ids.len()),
        "select between 2 and 200 physical files"
    );
    let track_ids = track_ids_for_files(pool, file_ids).await?;
    anyhow::ensure!(
        track_ids.len() >= 2,
        "the selected files must belong to at least two catalog tracks"
    );

    let target_track_id = requested_target_track_id.unwrap_or(track_ids[0]);
    anyhow::ensure!(
        track_ids.contains(&target_track_id),
        "the canonical track must belong to the selected files"
    );
    let identities = merge_identities(pool, &track_ids).await?;
    let target = identities
        .iter()
        .find(|identity| identity.track_id == target_track_id)
        .context("canonical track was not found")?;
    let sources = identities
        .iter()
        .filter(|identity| identity.track_id != target_track_id)
        .collect::<Vec<_>>();

    let mut conflicts = Vec::new();
    compare_text(
        &mut conflicts,
        "title",
        Some(target.title.as_str()),
        sources.iter().map(|source| Some(source.title.as_str())),
        "error",
    );
    compare_text(
        &mut conflicts,
        "artist",
        target.artist_display.as_deref(),
        sources
            .iter()
            .map(|source| source.artist_display.as_deref()),
        "error",
    );
    compare_text(
        &mut conflicts,
        "album",
        target.album_title.as_deref(),
        sources.iter().map(|source| source.album_title.as_deref()),
        "error",
    );
    compare_number(
        &mut conflicts,
        "disc_number",
        target.disc_number,
        sources.iter().map(|source| source.disc_number),
        "error",
    );
    compare_number(
        &mut conflicts,
        "track_number",
        target.track_number,
        sources.iter().map(|source| source.track_number),
        "error",
    );

    let duration_values = sources
        .iter()
        .filter_map(|source| {
            let target_duration = target.duration_ms?;
            let source_duration = source.duration_ms?;
            ((target_duration - source_duration).abs() > 2_000).then_some(source_duration)
        })
        .collect::<Vec<_>>();
    if !duration_values.is_empty() {
        let severe = target.duration_ms.is_some_and(|target_duration| {
            duration_values
                .iter()
                .any(|source| (target_duration - source).abs() > 15_000)
        });
        conflicts.push(TrackMergeConflict {
            field: "duration_ms".to_string(),
            target_value: target.duration_ms.map(|value| value.to_string()),
            source_values: duration_values
                .into_iter()
                .map(|value| value.to_string())
                .collect(),
            severity: if severe { "error" } else { "warning" }.to_string(),
        });
    }
    let known_kinds = sources
        .iter()
        .filter_map(|source| {
            (source.recording_kind != "unknown"
                && target.recording_kind != "unknown"
                && source.recording_kind != target.recording_kind)
                .then_some(source.recording_kind.clone())
        })
        .collect::<BTreeSet<_>>();
    if !known_kinds.is_empty() {
        conflicts.push(TrackMergeConflict {
            field: "recording_kind".to_string(),
            target_value: Some(target.recording_kind.clone()),
            source_values: known_kinds.into_iter().collect(),
            severity: "error".to_string(),
        });
    }

    let can_merge = !conflicts
        .iter()
        .any(|conflict| conflict.severity == "error");
    Ok(TrackMergePreview {
        target_track_id,
        source_track_ids: sources.iter().map(|source| source.track_id).collect(),
        candidates: identities
            .into_iter()
            .map(|identity| TrackMergeCandidate {
                track_id: identity.track_id,
                release_track_id: identity.release_track_id,
                title: identity.title,
                artist_display: identity.artist_display,
                album_id: identity.album_id,
                album_title: identity.album_title,
                disc_number: identity.disc_number,
                track_number: identity.track_number,
                duration_ms: identity.duration_ms,
                recording_kind: identity.recording_kind,
                file_count: identity.file_count,
                media_variant_count: identity.media_variant_count,
                is_target: identity.track_id == target_track_id,
            })
            .collect(),
        conflicts,
        can_merge,
    })
}

pub async fn merge_tracks(pool: &DbPool, request: &TrackMergeRequest) -> Result<TrackMergeResult> {
    let mut source_track_ids = request
        .source_track_ids
        .iter()
        .copied()
        .filter(|track_id| *track_id != request.target_track_id)
        .collect::<Vec<_>>();
    source_track_ids.sort_unstable();
    source_track_ids.dedup();
    anyhow::ensure!(
        (1..=199).contains(&source_track_ids.len()),
        "select between 1 and 199 source tracks"
    );

    let mut all_track_ids = vec![request.target_track_id];
    all_track_ids.extend(source_track_ids.iter().copied());
    let identities = merge_identities(pool, &all_track_ids).await?;
    anyhow::ensure!(
        identities.len() == all_track_ids.len(),
        "one or more catalog tracks no longer exist"
    );
    let target = identities
        .iter()
        .find(|identity| identity.track_id == request.target_track_id)
        .context("canonical track was not found")?;
    let selected_files = file_ids_for_tracks(pool, &all_track_ids).await?;
    let preview = preview_track_merge(pool, &selected_files, Some(request.target_track_id)).await?;
    anyhow::ensure!(
        preview.can_merge,
        "the selected tracks belong to different identities or releases"
    );
    anyhow::ensure!(
        preview.conflicts.is_empty() || request.confirm_conflicts,
        "review and confirm the metadata differences first"
    );

    let target_release_track_id = target.release_track_id;
    let target_recording_id = target.recording_id;
    let merge_id = Uuid::now_v7().to_string();
    let now = Utc::now().to_rfc3339();
    let mut transaction = pool.begin_with("BEGIN IMMEDIATE").await?;
    let mut previous_links = Vec::new();
    let mut inserted_relations = Vec::new();
    let mut previous_master_recordings = BTreeMap::<i64, i64>::new();
    let mut previous_resolutions = Vec::new();

    for source in identities
        .iter()
        .filter(|identity| identity.track_id != request.target_track_id)
    {
        previous_links.push(PreviousLink {
            track_id: source.track_id,
            release_track_id: source.release_track_id,
        });
        if source.release_track_id != target_release_track_id {
            let variants = sqlx::query(
                r#"
                SELECT relation.media_variant_id, variant.audio_master_id,
                       master.recording_id
                FROM release_track_media_variants relation
                JOIN media_variants variant ON variant.id = relation.media_variant_id
                JOIN audio_masters master ON master.id = variant.audio_master_id
                WHERE relation.release_track_id = ?1
                "#,
            )
            .bind(source.release_track_id)
            .fetch_all(&mut *transaction)
            .await?;
            for variant in variants {
                let media_variant_id: i64 = variant.try_get("media_variant_id")?;
                let master_id: i64 = variant.try_get("audio_master_id")?;
                let master_recording_id: i64 = variant.try_get("recording_id")?;
                previous_master_recordings
                    .entry(master_id)
                    .or_insert(master_recording_id);
                let existed: i64 = sqlx::query_scalar(
                    r#"
                    SELECT COUNT(*)
                    FROM release_track_media_variants
                    WHERE release_track_id = ?1 AND media_variant_id = ?2
                    "#,
                )
                .bind(target_release_track_id)
                .bind(media_variant_id)
                .fetch_one(&mut *transaction)
                .await?;
                if existed == 0 {
                    sqlx::query(
                        r#"
                        INSERT INTO release_track_media_variants (
                            release_track_id, media_variant_id, relation_kind,
                            is_preferred, created_at
                        )
                        VALUES (?1, ?2, 'exact', 0, ?3)
                        "#,
                    )
                    .bind(target_release_track_id)
                    .bind(media_variant_id)
                    .bind(&now)
                    .execute(&mut *transaction)
                    .await?;
                    inserted_relations.push(InsertedRelation {
                        release_track_id: target_release_track_id,
                        media_variant_id,
                    });
                }
            }
        }
        sqlx::query(
            r#"
            UPDATE legacy_track_catalog_links
            SET release_track_id = ?1, match_kind = 'confirmed_same_release',
                match_confidence = 1.0, updated_at = ?2
            WHERE track_id = ?3
            "#,
        )
        .bind(target_release_track_id)
        .bind(&now)
        .bind(source.track_id)
        .execute(&mut *transaction)
        .await?;
        let source_file_id: i64 = sqlx::query_scalar("SELECT file_id FROM tracks WHERE id = ?1")
            .bind(source.track_id)
            .fetch_one(&mut *transaction)
            .await?;
        let resolution_rows = sqlx::query(
            r#"
            SELECT file_id, resolution_kind, target_track_id, metadata_json
            FROM client_file_resolutions
            WHERE target_track_id = ?1 OR file_id = ?2
            "#,
        )
        .bind(source.track_id)
        .bind(source_file_id)
        .fetch_all(&mut *transaction)
        .await?;
        let mut direct_resolution_found = false;
        for row in resolution_rows {
            let file_id: i64 = row.try_get("file_id")?;
            direct_resolution_found |= file_id == source_file_id;
            previous_resolutions.push(PreviousResolution {
                file_id,
                resolution_kind: Some(row.try_get("resolution_kind")?),
                target_track_id: row.try_get("target_track_id")?,
                metadata_json: row.try_get("metadata_json")?,
            });
        }
        if !direct_resolution_found {
            previous_resolutions.push(PreviousResolution {
                file_id: source_file_id,
                resolution_kind: None,
                target_track_id: None,
                metadata_json: None,
            });
        }
        sqlx::query(
            "UPDATE client_file_resolutions SET target_track_id = ?1, updated_at = ?2 WHERE target_track_id = ?3",
        )
        .bind(request.target_track_id)
        .bind(&now)
        .bind(source.track_id)
        .execute(&mut *transaction)
        .await?;
        sqlx::query(
            r#"
            INSERT INTO client_file_resolutions (
                file_id, resolution_kind, target_track_id,
                metadata_json, created_at, updated_at
            )
            VALUES (?1, 'matched_track', ?2, NULL, ?3, ?3)
            ON CONFLICT(file_id) DO UPDATE SET
                resolution_kind = 'matched_track',
                target_track_id = excluded.target_track_id,
                updated_at = excluded.updated_at
            "#,
        )
        .bind(source_file_id)
        .bind(request.target_track_id)
        .bind(&now)
        .execute(&mut *transaction)
        .await?;
    }

    for master_id in previous_master_recordings.keys() {
        sqlx::query("UPDATE audio_masters SET recording_id = ?1, updated_at = ?2 WHERE id = ?3")
            .bind(target_recording_id)
            .bind(&now)
            .bind(master_id)
            .execute(&mut *transaction)
            .await?;
    }
    merge_user_track_state(
        &mut transaction,
        request.target_track_id,
        &source_track_ids,
        &now,
    )
    .await?;
    sqlx::query(
        r#"
        INSERT INTO track_merge_history (
            id, target_track_id, target_release_track_id, source_track_ids_json,
            previous_links_json, inserted_relations_json,
            previous_master_recordings_json, previous_resolutions_json, created_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
        "#,
    )
    .bind(&merge_id)
    .bind(request.target_track_id)
    .bind(target_release_track_id)
    .bind(serde_json::to_string(&source_track_ids)?)
    .bind(serde_json::to_string(&previous_links)?)
    .bind(serde_json::to_string(&inserted_relations)?)
    .bind(serde_json::to_string(
        &previous_master_recordings
            .into_iter()
            .map(|(master_id, recording_id)| PreviousMasterRecording {
                master_id,
                recording_id,
            })
            .collect::<Vec<_>>(),
    )?)
    .bind(serde_json::to_string(&previous_resolutions)?)
    .bind(&now)
    .execute(&mut *transaction)
    .await?;
    for source_track_id in &source_track_ids {
        sqlx::query(
            r#"
            INSERT INTO track_merge_members (
                track_id, canonical_track_id, merge_id, created_at
            )
            VALUES (?1, ?2, ?3, ?4)
            "#,
        )
        .bind(source_track_id)
        .bind(request.target_track_id)
        .bind(&merge_id)
        .bind(&now)
        .execute(&mut *transaction)
        .await?;
    }
    transaction.commit().await?;

    Ok(TrackMergeResult {
        merge_id,
        target_track_id: request.target_track_id,
        target_release_track_id,
        merged_tracks: source_track_ids.len() as u32,
        linked_media_variants: inserted_relations.len() as u32,
        state: "merged".to_string(),
    })
}

pub async fn undo_track_merge(pool: &DbPool, merge_id: &str) -> Result<TrackMergeResult> {
    let mut transaction = pool.begin().await?;
    let history = sqlx::query(
        r#"
        SELECT target_track_id, target_release_track_id, source_track_ids_json,
               previous_links_json, inserted_relations_json,
               previous_master_recordings_json, previous_resolutions_json,
               undone_at
        FROM track_merge_history
        WHERE id = ?1
        "#,
    )
    .bind(merge_id)
    .fetch_one(&mut *transaction)
    .await?;
    let undone_at: Option<String> = history.try_get("undone_at")?;
    anyhow::ensure!(undone_at.is_none(), "this track merge was already undone");
    let target_track_id: i64 = history.try_get("target_track_id")?;
    let target_release_track_id: i64 = history.try_get("target_release_track_id")?;
    let source_track_ids: Vec<i64> =
        serde_json::from_str(&history.try_get::<String, _>("source_track_ids_json")?)?;
    let previous_links: Vec<PreviousLink> =
        serde_json::from_str(&history.try_get::<String, _>("previous_links_json")?)?;
    let inserted_relations: Vec<InsertedRelation> =
        serde_json::from_str(&history.try_get::<String, _>("inserted_relations_json")?)?;
    let previous_masters: Vec<PreviousMasterRecording> =
        serde_json::from_str(&history.try_get::<String, _>("previous_master_recordings_json")?)?;
    let previous_resolutions: Vec<PreviousResolution> =
        serde_json::from_str(&history.try_get::<String, _>("previous_resolutions_json")?)?;
    let now = Utc::now().to_rfc3339();

    for link in previous_links {
        sqlx::query(
            r#"
            UPDATE legacy_track_catalog_links
            SET release_track_id = ?1, match_kind = 'merge_undone',
                match_confidence = 1.0, updated_at = ?2
            WHERE track_id = ?3
            "#,
        )
        .bind(link.release_track_id)
        .bind(&now)
        .bind(link.track_id)
        .execute(&mut *transaction)
        .await?;
    }
    for relation in &inserted_relations {
        sqlx::query(
            "DELETE FROM release_track_media_variants WHERE release_track_id = ?1 AND media_variant_id = ?2",
        )
        .bind(relation.release_track_id)
        .bind(relation.media_variant_id)
        .execute(&mut *transaction)
        .await?;
    }
    for master in previous_masters {
        sqlx::query("UPDATE audio_masters SET recording_id = ?1, updated_at = ?2 WHERE id = ?3")
            .bind(master.recording_id)
            .bind(&now)
            .bind(master.master_id)
            .execute(&mut *transaction)
            .await?;
    }
    for resolution in previous_resolutions {
        if let Some(resolution_kind) = resolution.resolution_kind {
            sqlx::query(
                r#"
                UPDATE client_file_resolutions
                SET resolution_kind = ?1, target_track_id = ?2,
                    metadata_json = ?3, updated_at = ?4
                WHERE file_id = ?5
                "#,
            )
            .bind(resolution_kind)
            .bind(resolution.target_track_id)
            .bind(resolution.metadata_json)
            .bind(&now)
            .bind(resolution.file_id)
            .execute(&mut *transaction)
            .await?;
        } else {
            sqlx::query("DELETE FROM client_file_resolutions WHERE file_id = ?1")
                .bind(resolution.file_id)
                .execute(&mut *transaction)
                .await?;
        }
    }
    sqlx::query("DELETE FROM track_merge_members WHERE merge_id = ?1")
        .bind(merge_id)
        .execute(&mut *transaction)
        .await?;
    sqlx::query("UPDATE track_merge_history SET undone_at = ?1 WHERE id = ?2")
        .bind(&now)
        .bind(merge_id)
        .execute(&mut *transaction)
        .await?;
    transaction.commit().await?;
    Ok(TrackMergeResult {
        merge_id: merge_id.to_string(),
        target_track_id,
        target_release_track_id,
        merged_tracks: source_track_ids.len() as u32,
        linked_media_variants: inserted_relations.len() as u32,
        state: "undone".to_string(),
    })
}

async fn track_ids_for_files(pool: &DbPool, file_ids: &[i64]) -> Result<Vec<i64>> {
    let mut builder = QueryBuilder::<Sqlite>::new(
        r#"
        SELECT DISTINCT COALESCE(
            resolution.target_track_id,
            direct_track.id,
            (
                SELECT MIN(link.track_id)
                FROM media_replicas replica
                JOIN release_track_media_variants relation
                  ON relation.media_variant_id = replica.media_variant_id
                JOIN legacy_track_catalog_links link
                  ON link.release_track_id = relation.release_track_id
                WHERE replica.file_id = file.id
            )
        ) AS track_id
        FROM files file
        LEFT JOIN tracks direct_track ON direct_track.file_id = file.id
        LEFT JOIN client_file_resolutions resolution ON resolution.file_id = file.id
        WHERE file.id IN (
        "#,
    );
    let mut separated = builder.separated(", ");
    for file_id in file_ids {
        separated.push_bind(file_id);
    }
    separated.push_unseparated(") ORDER BY track_id");
    Ok(builder
        .build()
        .fetch_all(pool)
        .await?
        .into_iter()
        .filter_map(|row| row.try_get::<Option<i64>, _>("track_id").ok().flatten())
        .collect())
}

async fn file_ids_for_tracks(pool: &DbPool, track_ids: &[i64]) -> Result<Vec<i64>> {
    let mut builder = QueryBuilder::<Sqlite>::new("SELECT file_id FROM tracks WHERE id IN (");
    let mut separated = builder.separated(", ");
    for track_id in track_ids {
        separated.push_bind(track_id);
    }
    separated.push_unseparated(") ORDER BY id");
    Ok(builder
        .build()
        .fetch_all(pool)
        .await?
        .into_iter()
        .map(|row| row.try_get("file_id"))
        .collect::<Result<Vec<_>, _>>()?)
}

async fn merge_identities(pool: &DbPool, track_ids: &[i64]) -> Result<Vec<MergeIdentity>> {
    let mut identities = Vec::with_capacity(track_ids.len());
    for track_id in track_ids {
        let row = sqlx::query(
            r#"
            SELECT
                track.id AS track_id,
                link.release_track_id,
                release_track.recording_id,
                track.title,
                album.id AS album_id,
                album.title AS album_title,
                track.disc_number,
                track.track_number,
                track.duration_ms,
                recording.recording_kind,
                (
                    SELECT GROUP_CONCAT(artist.name, '; ')
                    FROM track_artists credit
                    JOIN artists artist ON artist.id = credit.artist_id
                    WHERE credit.track_id = track.id AND credit.role = 'primary'
                    ORDER BY credit.position
                ) AS artist_display,
                (
                    SELECT COUNT(DISTINCT replica.file_id)
                    FROM release_track_media_variants relation
                    JOIN media_replicas replica
                      ON replica.media_variant_id = relation.media_variant_id
                    WHERE relation.release_track_id = link.release_track_id
                      AND replica.file_id IS NOT NULL
                ) AS file_count,
                (
                    SELECT COUNT(*)
                    FROM release_track_media_variants relation
                    WHERE relation.release_track_id = link.release_track_id
                ) AS media_variant_count
            FROM tracks track
            JOIN legacy_track_catalog_links link ON link.track_id = track.id
            JOIN release_tracks release_track ON release_track.id = link.release_track_id
            JOIN catalog_recordings recording ON recording.id = release_track.recording_id
            LEFT JOIN albums album ON album.id = track.album_id
            WHERE track.id = ?1
            "#,
        )
        .bind(track_id)
        .fetch_one(pool)
        .await?;
        identities.push(MergeIdentity {
            track_id: row.try_get("track_id")?,
            release_track_id: row.try_get("release_track_id")?,
            recording_id: row.try_get("recording_id")?,
            title: row.try_get("title")?,
            artist_display: row.try_get("artist_display")?,
            album_id: row.try_get("album_id")?,
            album_title: row.try_get("album_title")?,
            disc_number: row.try_get("disc_number")?,
            track_number: row.try_get("track_number")?,
            duration_ms: row.try_get("duration_ms")?,
            recording_kind: row.try_get("recording_kind")?,
            file_count: row.try_get("file_count")?,
            media_variant_count: row.try_get("media_variant_count")?,
        });
    }
    Ok(identities)
}

fn compare_text<'a>(
    conflicts: &mut Vec<TrackMergeConflict>,
    field: &str,
    target: Option<&str>,
    sources: impl Iterator<Item = Option<&'a str>>,
    severity: &str,
) {
    let target_normalized = target.map(normalize_text).unwrap_or_default();
    let source_values = sources
        .flatten()
        .filter(|value| normalize_text(value) != target_normalized)
        .map(str::to_string)
        .collect::<BTreeSet<_>>();
    if !source_values.is_empty() {
        conflicts.push(TrackMergeConflict {
            field: field.to_string(),
            target_value: target.map(str::to_string),
            source_values: source_values.into_iter().collect(),
            severity: severity.to_string(),
        });
    }
}

fn compare_number(
    conflicts: &mut Vec<TrackMergeConflict>,
    field: &str,
    target: Option<i64>,
    sources: impl Iterator<Item = Option<i64>>,
    severity: &str,
) {
    let source_values = sources
        .flatten()
        .filter(|value| Some(*value) != target)
        .map(|value| value.to_string())
        .collect::<BTreeSet<_>>();
    if !source_values.is_empty() {
        conflicts.push(TrackMergeConflict {
            field: field.to_string(),
            target_value: target.map(|value| value.to_string()),
            source_values: source_values.into_iter().collect(),
            severity: severity.to_string(),
        });
    }
}

async fn merge_user_track_state(
    transaction: &mut sqlx::Transaction<'_, Sqlite>,
    target_track_id: i64,
    source_track_ids: &[i64],
    now: &str,
) -> Result<()> {
    let mut builder = QueryBuilder::<Sqlite>::new(
        r#"
        SELECT
            MAX(COALESCE(is_favorite, 0)) AS is_favorite,
            MAX(user_rating) AS user_rating
        FROM user_track_state
        WHERE track_id IN (
        "#,
    );
    let mut separated = builder.separated(", ");
    separated.push_bind(target_track_id);
    for track_id in source_track_ids {
        separated.push_bind(track_id);
    }
    separated.push_unseparated(")");
    let row = builder.build().fetch_one(&mut **transaction).await?;
    let is_favorite: i64 = row.try_get("is_favorite")?;
    let user_rating: Option<i64> = row.try_get("user_rating")?;
    if is_favorite != 0 || user_rating.is_some() {
        sqlx::query(
            r#"
            INSERT INTO user_track_state (
                track_id, is_favorite, user_rating, rating_source,
                favorite_updated_at, rating_updated_at, created_at, updated_at
            )
            VALUES (?1, ?2, ?3, 'merged', ?4, ?4, ?4, ?4)
            ON CONFLICT(track_id) DO UPDATE SET
                is_favorite = MAX(user_track_state.is_favorite, excluded.is_favorite),
                user_rating = COALESCE(user_track_state.user_rating, excluded.user_rating),
                updated_at = excluded.updated_at
            "#,
        )
        .bind(target_track_id)
        .bind(is_favorite)
        .bind(user_rating)
        .bind(now)
        .execute(&mut **transaction)
        .await?;
    }
    Ok(())
}

pub(crate) async fn preserve_recording_user_state(
    transaction: &mut sqlx::Transaction<'_, Sqlite>,
    recording_id: i64,
    now: &str,
) -> Result<()> {
    let row = sqlx::query(
        r#"
        SELECT
            MIN(links.track_id) AS canonical_track_id,
            MAX(COALESCE(state.is_favorite, 0)) AS is_favorite,
            MAX(state.user_rating) AS user_rating
        FROM legacy_track_catalog_links links
        JOIN release_tracks release_track
          ON release_track.id = links.release_track_id
        LEFT JOIN track_merge_members member ON member.track_id = links.track_id
        LEFT JOIN user_track_state state ON state.track_id = links.track_id
        WHERE release_track.recording_id = ?1
          AND member.track_id IS NULL
        "#,
    )
    .bind(recording_id)
    .fetch_one(&mut **transaction)
    .await?;
    let canonical_track_id: Option<i64> = row.try_get("canonical_track_id")?;
    let is_favorite: i64 = row.try_get("is_favorite")?;
    let user_rating: Option<i64> = row.try_get("user_rating")?;
    let Some(canonical_track_id) = canonical_track_id else {
        return Ok(());
    };
    if is_favorite == 0 && user_rating.is_none() {
        return Ok(());
    }
    sqlx::query(
        r#"
        INSERT INTO user_track_state (
            track_id, is_favorite, user_rating, rating_source,
            favorite_updated_at, rating_updated_at, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, 'recording_link', ?4, ?4, ?4, ?4)
        ON CONFLICT(track_id) DO UPDATE SET
            is_favorite = MAX(user_track_state.is_favorite, excluded.is_favorite),
            user_rating = COALESCE(
                MAX(user_track_state.user_rating, excluded.user_rating),
                user_track_state.user_rating,
                excluded.user_rating
            ),
            updated_at = excluded.updated_at
        "#,
    )
    .bind(canonical_track_id)
    .bind(is_favorite)
    .bind(user_rating)
    .bind(now)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}
