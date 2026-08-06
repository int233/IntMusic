use super::*;

pub async fn album_detail(pool: &DbPool, album_id: i64) -> Result<AlbumDetail> {
    let album_row = sqlx::query(
        r#"
        SELECT canonical.id,
               COALESCE(NULLIF(profile.title, ''), canonical.title) AS title,
               COALESCE(NULLIF(profile.album_artist_display, ''), canonical.album_artist_display) AS album_artist_display,
               COALESCE(NULLIF(profile.date, ''), canonical.date, MAX(member_album.date)) AS date,
               COALESCE(profile.year, canonical.year, MAX(member_album.year)) AS year,
               COALESCE(profile.total_discs, MAX(member_album.total_discs)) AS total_discs,
               COALESCE(canonical.cover_asset_id, MAX(member_album.cover_asset_id)) AS cover_asset_id,
               COUNT(DISTINCT CASE WHEN member.track_id IS NULL THEN
                   COALESCE('release:' || links.release_track_id, 'legacy:' || t.id)
               END) AS track_count
        FROM album_identity_members requested
        JOIN album_identity_members identity
          ON identity.canonical_album_id = requested.canonical_album_id
        JOIN albums canonical ON canonical.id = requested.canonical_album_id
        LEFT JOIN album_metadata_profiles profile ON profile.album_id = canonical.id
        JOIN albums member_album ON member_album.id = identity.album_id
        JOIN tracks t ON t.album_id = member_album.id
        JOIN active_catalog_tracks active ON active.track_id = t.id
        LEFT JOIN legacy_track_catalog_links links ON links.track_id = t.id
        LEFT JOIN track_merge_members member ON member.track_id = t.id
        WHERE requested.album_id = ?1
        GROUP BY canonical.id
        "#,
    )
    .bind(album_id)
    .fetch_one(pool)
    .await?;

    let track_rows = sqlx::query(
        track_select_sql(
            r#"
            LEFT JOIN legacy_track_catalog_links current_link ON current_link.track_id = t.id
            JOIN album_identity_members track_album ON track_album.album_id = t.album_id
            JOIN album_identity_members requested_album
              ON requested_album.album_id = ?1
             AND requested_album.canonical_album_id = track_album.canonical_album_id
            JOIN active_catalog_tracks active ON active.track_id = t.id
            WHERE 1 = 1
              AND NOT EXISTS (
                SELECT 1 FROM track_merge_members member
                WHERE member.track_id = t.id
              )
              AND (
                current_link.track_id IS NULL
                OR t.id = (
                SELECT MIN(candidate.track_id)
                FROM legacy_track_catalog_links candidate
                LEFT JOIN track_merge_members member
                  ON member.track_id = candidate.track_id
                WHERE candidate.release_track_id = current_link.release_track_id
                  AND member.track_id IS NULL
                )
              )
            GROUP BY t.id
            ORDER BY COALESCE(t.disc_number, 1), COALESCE(t.track_number, 0), t.title
            "#,
        )
        .as_str(),
    )
    .bind(album_id)
    .fetch_all(pool)
    .await?;

    let canonical_id: i64 = album_row.try_get("id")?;
    Ok(AlbumDetail {
        album: row_to_album(album_row)?,
        tracks: track_rows
            .into_iter()
            .map(row_to_track)
            .collect::<Result<_>>()?,
        profile: album_metadata_profile(pool, canonical_id).await?,
        credits: album_credits(pool, canonical_id).await?,
    })
}

pub async fn track_media_profile(
    pool: &DbPool,
    track_id: i64,
) -> Result<Option<TrackMediaProfile>> {
    let row = sqlx::query(
        r#"
        SELECT
            rt.id AS release_track_id,
            work.id AS work_id,
            work.global_id AS work_global_id,
            work.title AS work_title,
            work.disambiguation AS work_disambiguation,
            recording.id AS recording_id,
            recording.global_id AS recording_global_id,
            recording.title AS recording_title,
            recording.version_title AS recording_version_title,
            recording.recording_kind,
            recording.duration_ms AS recording_duration_ms,
            release.id AS release_id,
            release.global_id AS release_global_id,
            release.album_id AS release_album_id,
            album.title AS release_title,
            release.edition_title AS release_edition_title,
            release.edition_kind AS release_edition_kind,
            album.date AS release_date,
            album.year AS release_year
        FROM legacy_track_catalog_links links
        JOIN release_tracks rt ON rt.id = links.release_track_id
        JOIN catalog_recordings recording ON recording.id = rt.recording_id
        JOIN catalog_works work ON work.id = recording.work_id
        LEFT JOIN release_editions release ON release.id = rt.release_id
        LEFT JOIN albums album ON album.id = release.album_id
        WHERE links.track_id = ?1
        "#,
    )
    .bind(track_id)
    .fetch_optional(pool)
    .await?;
    let Some(row) = row else {
        return Ok(None);
    };

    let release_track_id: i64 = row.try_get("release_track_id")?;
    let recording_id: i64 = row.try_get("recording_id")?;
    let work = CatalogWorkSummary {
        id: row.try_get("work_id")?,
        global_id: row.try_get("work_global_id")?,
        title: row.try_get("work_title")?,
        disambiguation: row.try_get("work_disambiguation")?,
    };
    let recording = CatalogRecordingSummary {
        id: recording_id,
        global_id: row.try_get("recording_global_id")?,
        title: row.try_get("recording_title")?,
        version_title: row.try_get("recording_version_title")?,
        recording_kind: row.try_get("recording_kind")?,
        duration_ms: row.try_get("recording_duration_ms")?,
    };
    let release = release_edition_from_row(&row)?;

    let variant_rows = sqlx::query(
        r#"
        SELECT
            variant.id,
            variant.global_id,
            GROUP_CONCAT(DISTINCT relation.release_track_id) AS release_track_ids,
            MIN(relation.relation_kind) AS relation_kind,
            MAX(relation.is_preferred) AS is_preferred,
            variant.codec,
            variant.container,
            variant.bitrate,
            variant.sample_rate,
            variant.bit_depth,
            variant.channels,
            variant.duration_ms,
            variant.content_hash,
            master.id AS master_id,
            master.global_id AS master_global_id,
            master.label AS master_label,
            master.mastering_kind,
            master.release_year AS master_release_year
        FROM release_track_media_variants relation
        JOIN release_tracks related_track ON related_track.id = relation.release_track_id
        JOIN media_variants variant ON variant.id = relation.media_variant_id
        JOIN audio_masters master ON master.id = variant.audio_master_id
        WHERE related_track.recording_id = ?1
          AND EXISTS (
            SELECT 1
            FROM legacy_track_catalog_links active_link
            LEFT JOIN track_merge_members member
              ON member.track_id = active_link.track_id
            WHERE active_link.release_track_id = related_track.id
              AND member.track_id IS NULL
          )
        GROUP BY variant.id
        ORDER BY MAX(relation.is_preferred) DESC,
                 COALESCE(variant.bit_depth, 0) DESC,
                 COALESCE(variant.sample_rate, 0) DESC,
                 COALESCE(variant.bitrate, 0) DESC,
                 variant.id
        "#,
    )
    .bind(recording_id)
    .fetch_all(pool)
    .await?;

    // Fetch every physical copy in one round trip. A track may expose several
    // quality variants, so querying replicas inside the variant loop turns the
    // detail endpoint into an avoidable N+1 query path.
    let replica_rows = sqlx::query(
        r#"
        SELECT
            replica.media_variant_id,
            replica.id,
            replica.file_id,
            replica.device_id,
            COALESCE(device.name, 'Core local') AS device_name,
            replica.source_kind,
            CASE
                WHEN file.deleted_at IS NOT NULL THEN 'missing'
                ELSE replica.availability_state
            END AS availability_state,
            replica.is_primary,
            file.relative_path,
            root.external_id AS root_external_id,
            file.client_file_id,
            replica.last_verified_at,
            file.extension,
            file.size_bytes,
            file.modified_at,
            file.codec,
            file.bitrate,
            file.sample_rate,
            file.bit_depth,
            file.channels,
            file.duration_ms
        FROM media_replicas replica
        LEFT JOIN devices device ON device.id = replica.device_id
        LEFT JOIN files file ON file.id = replica.file_id
        LEFT JOIN library_roots root ON root.id = replica.library_root_id
        WHERE replica.media_variant_id IN (
            SELECT relation.media_variant_id
            FROM release_track_media_variants relation
            JOIN release_tracks related_track
              ON related_track.id = relation.release_track_id
            WHERE related_track.recording_id = ?1
              AND EXISTS (
                SELECT 1
                FROM legacy_track_catalog_links active_link
                LEFT JOIN track_merge_members member
                  ON member.track_id = active_link.track_id
                WHERE active_link.release_track_id = related_track.id
                  AND member.track_id IS NULL
                )
        )
          AND replica.availability_state NOT IN ('retired', 'ignored')
          AND (
              root.id IS NULL
              OR (
                  root.removed_at IS NULL
                  AND root.retired_at IS NULL
                  AND root.enabled = 1
              )
          )
          AND (
              device.id IS NULL
              OR (
                  device.removed_at IS NULL
                  AND device.retired_at IS NULL
              )
          )
        ORDER BY replica.media_variant_id,
                 replica.is_primary DESC,
                 device_name,
                 replica.id
        "#,
    )
    .bind(recording_id)
    .fetch_all(pool)
    .await?;
    let mut replicas_by_variant = HashMap::<i64, Vec<MediaReplicaSummary>>::new();
    for replica_row in replica_rows {
        let variant_id: i64 = replica_row.try_get("media_variant_id")?;
        let last_verified_at: Option<String> = replica_row.try_get("last_verified_at")?;
        let modified_at: Option<String> = replica_row.try_get("modified_at")?;
        replicas_by_variant
            .entry(variant_id)
            .or_default()
            .push(MediaReplicaSummary {
                id: replica_row.try_get("id")?,
                file_id: replica_row.try_get("file_id")?,
                device_id: replica_row.try_get("device_id")?,
                device_name: replica_row.try_get("device_name")?,
                source_kind: replica_row.try_get("source_kind")?,
                availability_state: replica_row.try_get("availability_state")?,
                is_primary: replica_row.try_get::<i64, _>("is_primary")? != 0,
                relative_path: replica_row.try_get("relative_path")?,
                root_external_id: replica_row.try_get("root_external_id")?,
                client_file_id: replica_row.try_get("client_file_id")?,
                last_verified_at: last_verified_at.map(parse_datetime).transpose()?,
                extension: replica_row.try_get("extension")?,
                size_bytes: replica_row.try_get("size_bytes")?,
                modified_at: modified_at.map(parse_datetime).transpose()?,
                codec: replica_row.try_get("codec")?,
                bitrate: replica_row.try_get("bitrate")?,
                sample_rate: replica_row.try_get("sample_rate")?,
                bit_depth: replica_row.try_get("bit_depth")?,
                channels: replica_row.try_get("channels")?,
                duration_ms: replica_row.try_get("duration_ms")?,
            });
    }

    let mut variants = Vec::with_capacity(variant_rows.len());
    for variant_row in variant_rows {
        let variant_id: i64 = variant_row.try_get("id")?;
        let replicas = replicas_by_variant.remove(&variant_id).unwrap_or_default();
        variants.push(MediaVariantSummary {
            id: variant_id,
            global_id: variant_row.try_get("global_id")?,
            release_track_ids: variant_row
                .try_get::<String, _>("release_track_ids")?
                .split(',')
                .filter_map(|value| value.parse().ok())
                .collect(),
            relation_kind: variant_row.try_get("relation_kind")?,
            is_preferred: variant_row.try_get::<i64, _>("is_preferred")? != 0,
            codec: variant_row.try_get("codec")?,
            container: variant_row.try_get("container")?,
            bitrate: variant_row.try_get("bitrate")?,
            sample_rate: variant_row.try_get("sample_rate")?,
            bit_depth: variant_row.try_get("bit_depth")?,
            channels: variant_row.try_get("channels")?,
            duration_ms: variant_row.try_get("duration_ms")?,
            content_hash: variant_row.try_get("content_hash")?,
            master: AudioMasterSummary {
                id: variant_row.try_get("master_id")?,
                global_id: variant_row.try_get("master_global_id")?,
                label: variant_row.try_get("master_label")?,
                mastering_kind: variant_row.try_get("mastering_kind")?,
                release_year: variant_row.try_get("master_release_year")?,
            },
            replicas,
        });
    }

    let related_rows = sqlx::query(
        r#"
        SELECT
            rt.id AS related_release_track_id,
            MIN(CASE WHEN member.track_id IS NULL THEN links.track_id END) AS legacy_track_id,
            rt.title,
            rt.disc_number,
            rt.track_number,
            release.id AS release_id,
            release.global_id AS release_global_id,
            release.album_id AS release_album_id,
            album.title AS release_title,
            release.edition_title AS release_edition_title,
            release.edition_kind AS release_edition_kind,
            album.date AS release_date,
            album.year AS release_year
        FROM release_tracks rt
        LEFT JOIN legacy_track_catalog_links links ON links.release_track_id = rt.id
        LEFT JOIN track_merge_members member ON member.track_id = links.track_id
        LEFT JOIN release_editions release ON release.id = rt.release_id
        LEFT JOIN albums album ON album.id = release.album_id
        WHERE rt.recording_id = ?1
          AND EXISTS (
            SELECT 1
            FROM legacy_track_catalog_links active_link
            LEFT JOIN track_merge_members active_member
              ON active_member.track_id = active_link.track_id
            WHERE active_link.release_track_id = rt.id
              AND active_member.track_id IS NULL
          )
        GROUP BY rt.id
        ORDER BY COALESCE(album.year, 0), COALESCE(album.title, ''), rt.disc_number, rt.track_number
        "#,
    )
    .bind(recording_id)
    .fetch_all(pool)
    .await?;
    let related_release_tracks = related_rows
        .into_iter()
        .map(|related_row| {
            let related_release_track_id: i64 = related_row.try_get("related_release_track_id")?;
            Ok(RelatedReleaseTrackSummary {
                release_track_id: related_release_track_id,
                legacy_track_id: related_row.try_get("legacy_track_id")?,
                release: release_edition_from_row(&related_row)?,
                title: related_row.try_get("title")?,
                disc_number: related_row.try_get("disc_number")?,
                track_number: related_row.try_get("track_number")?,
                is_current: related_release_track_id == release_track_id,
            })
        })
        .collect::<Result<Vec<_>>>()?;

    Ok(Some(TrackMediaProfile {
        release_track_id,
        work,
        recording,
        release,
        variants,
        related_release_tracks,
    }))
}

pub async fn recording_link_candidates(
    pool: &DbPool,
    track_id: i64,
    limit: u32,
) -> Result<Vec<RecordingLinkCandidate>> {
    let target = sqlx::query(
        r#"
        SELECT
            t.title,
            t.duration_ms,
            rt.recording_id,
            recording.recording_kind,
            COALESCE(GROUP_CONCAT(artist.name, char(31)), '') AS artists
        FROM tracks t
        JOIN legacy_track_catalog_links links ON links.track_id = t.id
        JOIN release_tracks rt ON rt.id = links.release_track_id
        JOIN catalog_recordings recording ON recording.id = rt.recording_id
        LEFT JOIN track_artists ta ON ta.track_id = t.id AND ta.role = 'primary'
        LEFT JOIN artists artist ON artist.id = ta.artist_id
        WHERE t.id = ?1
        GROUP BY t.id
        "#,
    )
    .bind(track_id)
    .fetch_one(pool)
    .await?;
    let target_title: String = target.try_get("title")?;
    let target_duration: Option<i64> = target.try_get("duration_ms")?;
    let target_recording_id: i64 = target.try_get("recording_id")?;
    let target_recording_kind: String = target.try_get("recording_kind")?;
    let target_artists = normalized_artist_names(&target.try_get::<String, _>("artists")?);

    let rows = sqlx::query(
        r#"
        SELECT
            t.id AS track_id,
            rt.id AS release_track_id,
            rt.recording_id,
            recording.recording_kind,
            t.title,
            t.duration_ms,
            t.album_id,
            album.title AS album_title,
            album.year,
            t.disc_number,
            t.track_number,
            COALESCE(GROUP_CONCAT(artist.name, char(31)), '') AS artists,
            COALESCE(GROUP_CONCAT(DISTINCT artist.name), NULL) AS artist_display
        FROM tracks t
        JOIN legacy_track_catalog_links links ON links.track_id = t.id
        JOIN release_tracks rt ON rt.id = links.release_track_id
        JOIN catalog_recordings recording ON recording.id = rt.recording_id
        LEFT JOIN albums album ON album.id = t.album_id
        LEFT JOIN track_artists ta ON ta.track_id = t.id AND ta.role = 'primary'
        LEFT JOIN artists artist ON artist.id = ta.artist_id
        WHERE t.id <> ?1
          AND lower(trim(t.title)) = lower(trim(?2))
          AND (
              ?3 IS NULL
              OR t.duration_ms IS NULL
              OR ABS(t.duration_ms - ?3) <= 15000
          )
        GROUP BY t.id
        LIMIT 250
        "#,
    )
    .bind(track_id)
    .bind(&target_title)
    .bind(target_duration)
    .fetch_all(pool)
    .await?;

    let mut candidates = Vec::new();
    for row in rows {
        let recording_id: i64 = row.try_get("recording_id")?;
        let duration_ms: Option<i64> = row.try_get("duration_ms")?;
        let recording_kind: String = row.try_get("recording_kind")?;
        let artists = normalized_artist_names(&row.try_get::<String, _>("artists")?);
        let mut confidence = 0.45_f32;
        let mut reasons = vec!["same_title".to_string()];
        if !target_artists.is_empty()
            && target_artists.iter().any(|artist| artists.contains(artist))
        {
            confidence += 0.25;
            reasons.push("same_primary_artist".to_string());
        }
        if let (Some(target_duration), Some(duration_ms)) = (target_duration, duration_ms) {
            let difference = (target_duration - duration_ms).abs();
            if difference <= 1_000 {
                confidence += 0.2;
                reasons.push("duration_within_1s".to_string());
            } else if difference <= 3_000 {
                confidence += 0.15;
                reasons.push("duration_within_3s".to_string());
            } else if difference <= 10_000 {
                confidence += 0.08;
                reasons.push("duration_within_10s".to_string());
            }
        }
        if target_recording_kind != "unknown" && recording_kind == target_recording_kind {
            confidence += 0.1;
            reasons.push("same_recording_kind".to_string());
        }
        let already_linked = recording_id == target_recording_id;
        if already_linked {
            confidence = 1.0;
            reasons.push("already_linked".to_string());
        }
        if confidence < 0.55 {
            continue;
        }
        candidates.push(RecordingLinkCandidate {
            track_id: row.try_get("track_id")?,
            release_track_id: row.try_get("release_track_id")?,
            recording_id,
            title: row.try_get("title")?,
            artist_display: row.try_get("artist_display")?,
            album_id: row.try_get("album_id")?,
            album_title: row.try_get("album_title")?,
            year: row.try_get("year")?,
            disc_number: row.try_get("disc_number")?,
            track_number: row.try_get("track_number")?,
            duration_ms,
            already_linked,
            confidence: confidence.min(1.0),
            reasons,
        });
    }
    candidates.sort_by(|left, right| {
        right
            .already_linked
            .cmp(&left.already_linked)
            .then_with(|| {
                right
                    .confidence
                    .partial_cmp(&left.confidence)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .then_with(|| left.album_title.cmp(&right.album_title))
            .then_with(|| left.track_id.cmp(&right.track_id))
    });
    candidates.truncate(limit.clamp(1, 100) as usize);
    Ok(candidates)
}

fn normalized_artist_names(value: &str) -> Vec<String> {
    let mut names = value
        .split('\u{1f}')
        .map(normalize_text)
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>();
    names.sort();
    names.dedup();
    names
}

pub async fn link_track_to_recording(
    pool: &DbPool,
    track_id: i64,
    source_track_id: i64,
) -> Result<TrackMediaProfile> {
    if track_id == source_track_id {
        bail!("a release track cannot be linked to itself");
    }
    let mut transaction = pool.begin().await?;
    let source_recording_id: i64 = sqlx::query_scalar(
        r#"
        SELECT rt.recording_id
        FROM legacy_track_catalog_links links
        JOIN release_tracks rt ON rt.id = links.release_track_id
        WHERE links.track_id = ?1
        "#,
    )
    .bind(source_track_id)
    .fetch_one(&mut *transaction)
    .await?;
    let target_release_track_id: i64 = sqlx::query_scalar(
        "SELECT release_track_id FROM legacy_track_catalog_links WHERE track_id = ?1",
    )
    .bind(track_id)
    .fetch_one(&mut *transaction)
    .await?;
    let now = Utc::now().to_rfc3339();
    sqlx::query("UPDATE release_tracks SET recording_id = ?1, updated_at = ?2 WHERE id = ?3")
        .bind(source_recording_id)
        .bind(&now)
        .bind(target_release_track_id)
        .execute(&mut *transaction)
        .await?;
    sqlx::query(
        r#"
        UPDATE audio_masters
        SET recording_id = ?1, updated_at = ?2
        WHERE id IN (
            SELECT variant.audio_master_id
            FROM release_track_media_variants relation
            JOIN media_variants variant ON variant.id = relation.media_variant_id
            WHERE relation.release_track_id = ?3
        )
        "#,
    )
    .bind(source_recording_id)
    .bind(&now)
    .bind(target_release_track_id)
    .execute(&mut *transaction)
    .await?;
    sqlx::query(
        r#"
        UPDATE legacy_track_catalog_links
        SET match_kind = 'confirmed_recording', match_confidence = 1.0, updated_at = ?1
        WHERE track_id = ?2
        "#,
    )
    .bind(&now)
    .bind(track_id)
    .execute(&mut *transaction)
    .await?;
    preserve_recording_user_state(&mut transaction, source_recording_id, &now).await?;
    transaction.commit().await?;
    track_media_profile(pool, track_id)
        .await?
        .context("track media profile is missing after recording link")
}

pub async fn detach_track_recording(pool: &DbPool, track_id: i64) -> Result<TrackMediaProfile> {
    let mut transaction = pool.begin().await?;
    let identity = sqlx::query(
        r#"
        SELECT
            links.release_track_id,
            t.title,
            t.subtitle,
            t.duration_ms
        FROM tracks t
        JOIN legacy_track_catalog_links links ON links.track_id = t.id
        WHERE t.id = ?1
        "#,
    )
    .bind(track_id)
    .fetch_one(&mut *transaction)
    .await?;
    let release_track_id: i64 = identity.try_get("release_track_id")?;
    let title: String = identity.try_get("title")?;
    let subtitle: Option<String> = identity.try_get("subtitle")?;
    let duration_ms: Option<i64> = identity.try_get("duration_ms")?;
    let now = Utc::now().to_rfc3339();
    let work_id: i64 = sqlx::query_scalar(
        r#"
        INSERT INTO catalog_works (
            global_id, title, normalized_title, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?4)
        RETURNING id
        "#,
    )
    .bind(Uuid::now_v7().to_string())
    .bind(&title)
    .bind(normalize_text(&title))
    .bind(&now)
    .fetch_one(&mut *transaction)
    .await?;
    let recording_id: i64 = sqlx::query_scalar(
        r#"
        INSERT INTO catalog_recordings (
            global_id, work_id, title, version_title, recording_kind,
            duration_ms, created_at, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)
        RETURNING id
        "#,
    )
    .bind(Uuid::now_v7().to_string())
    .bind(work_id)
    .bind(&title)
    .bind(&subtitle)
    .bind(inferred_recording_kind(subtitle.as_deref()))
    .bind(duration_ms)
    .bind(&now)
    .fetch_one(&mut *transaction)
    .await?;
    sqlx::query("UPDATE release_tracks SET recording_id = ?1, updated_at = ?2 WHERE id = ?3")
        .bind(recording_id)
        .bind(&now)
        .bind(release_track_id)
        .execute(&mut *transaction)
        .await?;
    sqlx::query(
        r#"
        UPDATE audio_masters
        SET recording_id = ?1, updated_at = ?2
        WHERE id IN (
            SELECT variant.audio_master_id
            FROM release_track_media_variants relation
            JOIN media_variants variant ON variant.id = relation.media_variant_id
            WHERE relation.release_track_id = ?3
        )
        "#,
    )
    .bind(recording_id)
    .bind(&now)
    .bind(release_track_id)
    .execute(&mut *transaction)
    .await?;
    sqlx::query(
        r#"
        UPDATE legacy_track_catalog_links
        SET match_kind = 'detached', match_confidence = 1.0, updated_at = ?1
        WHERE track_id = ?2
        "#,
    )
    .bind(&now)
    .bind(track_id)
    .execute(&mut *transaction)
    .await?;
    transaction.commit().await?;
    track_media_profile(pool, track_id)
        .await?
        .context("track media profile is missing after recording detach")
}

fn release_edition_from_row(
    row: &sqlx::sqlite::SqliteRow,
) -> Result<Option<ReleaseEditionSummary>> {
    let id: Option<i64> = row.try_get("release_id")?;
    let Some(id) = id else {
        return Ok(None);
    };
    Ok(Some(ReleaseEditionSummary {
        id,
        global_id: row.try_get("release_global_id")?,
        album_id: row.try_get("release_album_id")?,
        title: row.try_get("release_title")?,
        edition_title: row.try_get("release_edition_title")?,
        edition_kind: row.try_get("release_edition_kind")?,
        date: row.try_get("release_date")?,
        year: row.try_get("release_year")?,
    }))
}

pub async fn track_detail(pool: &DbPool, track_id: i64) -> Result<TrackDetail> {
    let track_row = sqlx::query(track_select_sql("WHERE t.id = ?1 GROUP BY t.id").as_str())
        .bind(track_id)
        .fetch_one(pool)
        .await?;
    let track = row_to_track(track_row)?;

    let file_row = sqlx::query(
        r#"
        SELECT f.path, f.relative_path, f.extension, f.size_bytes, f.modified_at, f.scan_status
        FROM tracks t
        JOIN files f ON f.id = t.file_id
        JOIN library_roots root ON root.id = f.library_root_id
        LEFT JOIN devices device ON device.id = root.owner_device_id
        WHERE t.id = ?1
          AND f.deleted_at IS NULL
          AND root.enabled = 1
          AND root.retired_at IS NULL
          AND root.removed_at IS NULL
          AND (
              device.id IS NULL
              OR (
                  device.retired_at IS NULL
                  AND device.removed_at IS NULL
              )
          )
        "#,
    )
    .bind(track_id)
    .fetch_optional(pool)
    .await?;

    let genres = sqlx::query(
        r#"
        SELECT g.name
        FROM track_genres tg
        JOIN genres g ON g.id = tg.genre_id
        WHERE tg.track_id = ?1
        ORDER BY g.name
        "#,
    )
    .bind(track_id)
    .fetch_all(pool)
    .await?
    .into_iter()
    .map(|row| row.try_get("name"))
    .collect::<Result<Vec<String>, sqlx::Error>>()?;
    let composers = track_artist_role_names(pool, track_id, "composer").await?;
    let lyricists = track_artist_role_names(pool, track_id, "lyricist").await?;

    let lyrics = sqlx::query(
        r#"
        SELECT kind, text, language, translation_text, pronunciation_text,
               offset_ms, source, revision, parsed_json
        FROM lyrics
        WHERE track_id = ?1
        "#,
    )
    .bind(track_id)
    .fetch_optional(pool)
    .await?
    .map(|row| {
        let parsed_json: Option<String> = row.try_get("parsed_json")?;
        Ok::<_, sqlx::Error>(LyricPayload {
            kind: row.try_get("kind")?,
            text: row.try_get("text")?,
            language: row.try_get("language")?,
            translation: row.try_get("translation_text")?,
            pronunciation: row.try_get("pronunciation_text")?,
            offset_ms: row.try_get("offset_ms")?,
            source: row.try_get("source")?,
            revision: row.try_get("revision")?,
            cues: parsed_json
                .as_deref()
                .and_then(|value| serde_json::from_str(value).ok())
                .unwrap_or_default(),
        })
    })
    .transpose()?;

    let file_path = file_row
        .as_ref()
        .and_then(|row| row.try_get("path").ok())
        .unwrap_or_default();
    let relative_path = file_row
        .as_ref()
        .and_then(|row| row.try_get("relative_path").ok())
        .unwrap_or_default();
    let extension = file_row
        .as_ref()
        .and_then(|row| row.try_get("extension").ok())
        .unwrap_or_default();
    let size_bytes = file_row
        .as_ref()
        .and_then(|row| row.try_get("size_bytes").ok())
        .unwrap_or_default();
    let modified_at = file_row
        .as_ref()
        .and_then(|row| row.try_get::<String, _>("modified_at").ok())
        .map(parse_datetime)
        .transpose()?
        .unwrap_or_else(Utc::now);
    let scan_status = file_row
        .as_ref()
        .and_then(|row| row.try_get("scan_status").ok())
        .unwrap_or_else(|| "missing".to_string());

    Ok(TrackDetail {
        track,
        file_path,
        relative_path,
        extension,
        size_bytes,
        modified_at,
        scan_status,
        genres,
        composers,
        lyricists,
        lyrics,
        media: track_media_profile(pool, track_id).await?,
    })
}
