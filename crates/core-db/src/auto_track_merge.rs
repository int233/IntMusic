use std::collections::{BTreeMap, BTreeSet};

use super::*;

const MAX_DURATION_DELTA_MS: i64 = 2_000;
const DEFAULT_PREVIEW_LIMIT: u32 = 200;
const MAX_PREVIEW_LIMIT: u32 = 500;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct ExactIdentityKey {
    title: String,
    artist: String,
    album: String,
    subtitle: Option<String>,
    year: Option<i64>,
    disc_number: Option<i64>,
    track_number: Option<i64>,
    recording_kind: String,
}

#[derive(Debug, Clone)]
struct ExactIdentity {
    track_id: i64,
    release_track_id: i64,
    title: String,
    artist_display: String,
    album_title: String,
    subtitle: Option<String>,
    year: Option<i64>,
    disc_number: Option<i64>,
    track_number: Option<i64>,
    duration_ms: i64,
    recording_kind: String,
    file_count: i64,
    media_variant_count: i64,
    canonical_score: i64,
}

pub async fn preview_exact_track_merges(
    pool: &DbPool,
    requested_limit: Option<u32>,
) -> Result<AutoTrackMergePreview> {
    let limit = requested_limit
        .unwrap_or(DEFAULT_PREVIEW_LIMIT)
        .clamp(1, MAX_PREVIEW_LIMIT) as usize;
    let identities = exact_identity_candidates(pool).await?;
    let mut keyed = BTreeMap::<ExactIdentityKey, Vec<ExactIdentity>>::new();
    for identity in identities {
        let key = ExactIdentityKey {
            title: normalize_text(&identity.title),
            artist: normalize_text(&identity.artist_display),
            album: normalize_text(&identity.album_title),
            subtitle: normalize_optional(identity.subtitle.as_deref()),
            year: identity.year,
            disc_number: identity.disc_number,
            track_number: identity.track_number,
            recording_kind: identity.recording_kind.clone(),
        };
        keyed.entry(key).or_default().push(identity);
    }

    let mut all_groups = Vec::new();
    for identities in keyed.into_values() {
        for cluster in duration_clusters(identities) {
            if let Some(group) = exact_group(cluster) {
                all_groups.push(group);
            }
        }
    }
    all_groups.sort_by(|left, right| {
        normalize_text(&left.album_title)
            .cmp(&normalize_text(&right.album_title))
            .then_with(|| {
                normalize_text(&left.artist_display).cmp(&normalize_text(&right.artist_display))
            })
            .then_with(|| normalize_text(&left.title).cmp(&normalize_text(&right.title)))
            .then_with(|| left.disc_number.cmp(&right.disc_number))
            .then_with(|| left.track_number.cmp(&right.track_number))
    });

    let duplicate_groups = all_groups.len() as u32;
    let duplicate_tracks = all_groups.iter().map(|group| group.track_count).sum();
    let physical_files = all_groups.iter().map(|group| group.file_count).sum();
    let truncated = all_groups.len() > limit;
    all_groups.truncate(limit);
    Ok(AutoTrackMergePreview {
        groups: all_groups,
        duplicate_groups,
        duplicate_tracks,
        physical_files,
        truncated,
    })
}

pub async fn merge_exact_track_groups(
    pool: &DbPool,
    request: &AutoTrackMergeRequest,
) -> Result<AutoTrackMergeResult> {
    anyhow::ensure!(
        (1..=MAX_PREVIEW_LIMIT as usize).contains(&request.group_ids.len()),
        "select between 1 and {MAX_PREVIEW_LIMIT} exact duplicate groups"
    );
    let selected = request.group_ids.iter().cloned().collect::<BTreeSet<_>>();
    anyhow::ensure!(
        selected.len() == request.group_ids.len(),
        "duplicate group IDs are not allowed"
    );
    let preview = preview_exact_track_merges(pool, Some(MAX_PREVIEW_LIMIT)).await?;
    let available = preview
        .groups
        .into_iter()
        .map(|group| (group.group_id.clone(), group))
        .collect::<BTreeMap<_, _>>();

    let mut result = AutoTrackMergeResult {
        merged_groups: 0,
        merged_tracks: 0,
        skipped_groups: 0,
        merge_ids: Vec::new(),
        failures: Vec::new(),
    };
    for group_id in selected {
        let Some(group) = available.get(&group_id) else {
            result.skipped_groups += 1;
            result.failures.push(AutoTrackMergeFailure {
                group_id,
                message: "The duplicate group changed after preview; scan again.".to_string(),
            });
            continue;
        };
        match merge_tracks(
            pool,
            &TrackMergeRequest {
                target_track_id: group.target_track_id,
                source_track_ids: group.source_track_ids.clone(),
                confirm_conflicts: false,
            },
        )
        .await
        {
            Ok(merged) => {
                result.merged_groups += 1;
                result.merged_tracks += merged.merged_tracks;
                result.merge_ids.push(merged.merge_id);
            }
            Err(error) => {
                result.skipped_groups += 1;
                result.failures.push(AutoTrackMergeFailure {
                    group_id,
                    message: format!("{error:#}"),
                });
            }
        }
    }
    Ok(result)
}

async fn exact_identity_candidates(pool: &DbPool) -> Result<Vec<ExactIdentity>> {
    let rows = sqlx::query(
        r#"
        SELECT
            track.id AS track_id,
            link.release_track_id,
            track.title,
            track.subtitle,
            track.year,
            track.disc_number,
            track.track_number,
            track.duration_ms,
            album.title AS album_title,
            recording.recording_kind,
            (
                SELECT GROUP_CONCAT(ordered_artist.name, '; ')
                FROM (
                    SELECT artist.name
                    FROM track_artists credit
                    JOIN artists artist ON artist.id = credit.artist_id
                    WHERE credit.track_id = track.id AND credit.role = 'primary'
                    ORDER BY credit.position, artist.id
                ) ordered_artist
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
            ) AS media_variant_count,
            (
                CASE
                    WHEN file.deleted_at IS NULL
                     AND file.availability_state = 'ready' THEN 1000000000000000
                    ELSE 0
                END
                + CASE WHEN track.cover_asset_id IS NOT NULL THEN 100000000000000 ELSE 0 END
                + CASE WHEN track.lyrics_id IS NOT NULL THEN 50000000000000 ELSE 0 END
                + (
                    (CASE WHEN track.subtitle IS NOT NULL AND trim(track.subtitle) <> '' THEN 1 ELSE 0 END)
                    + (CASE WHEN track.year IS NOT NULL THEN 1 ELSE 0 END)
                    + (CASE WHEN track.date IS NOT NULL AND trim(track.date) <> '' THEN 1 ELSE 0 END)
                    + (CASE WHEN track.comment IS NOT NULL AND trim(track.comment) <> '' THEN 1 ELSE 0 END)
                  ) * 1000000000000
                + COALESCE(file.bit_depth, 0) * 1000000000
                + COALESCE(file.sample_rate, 0) * 1000
                + COALESCE(file.bitrate, 0)
            ) AS canonical_score
        FROM tracks track
        JOIN files file ON file.id = track.file_id
        JOIN legacy_track_catalog_links link ON link.track_id = track.id
        JOIN release_tracks release_track ON release_track.id = link.release_track_id
        JOIN catalog_recordings recording ON recording.id = release_track.recording_id
        JOIN albums album ON album.id = track.album_id
        WHERE file.deleted_at IS NULL
          AND file.scan_status IN ('ok', 'identified')
          AND track.duration_ms IS NOT NULL
          AND trim(track.title) <> ''
          AND trim(album.title) <> ''
          AND NOT EXISTS (
              SELECT 1
              FROM track_merge_members member
              WHERE member.track_id = track.id
          )
          AND NOT EXISTS (
              SELECT 1
              FROM library_file_issues issue
              WHERE issue.file_id = file.id
                AND issue.state = 'open'
                AND issue.issue_kind IN (
                    'tag_parse_error',
                    'missing_required_tags',
                    'legacy_unverified',
                    'rescan_requested'
                )
          )
        ORDER BY track.id
        "#,
    )
    .fetch_all(pool)
    .await?;
    let mut identities = Vec::with_capacity(rows.len());
    for row in rows {
        let artist_display = row
            .try_get::<Option<String>, _>("artist_display")?
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty());
        let Some(artist_display) = artist_display else {
            continue;
        };
        if normalize_text(&artist_display) == "unknown artist" {
            continue;
        }
        identities.push(ExactIdentity {
            track_id: row.try_get("track_id")?,
            release_track_id: row.try_get("release_track_id")?,
            title: row.try_get("title")?,
            artist_display,
            album_title: row.try_get("album_title")?,
            subtitle: row.try_get("subtitle")?,
            year: row.try_get("year")?,
            disc_number: row.try_get("disc_number")?,
            track_number: row.try_get("track_number")?,
            duration_ms: row.try_get("duration_ms")?,
            recording_kind: row.try_get("recording_kind")?,
            file_count: row.try_get("file_count")?,
            media_variant_count: row.try_get("media_variant_count")?,
            canonical_score: row.try_get("canonical_score")?,
        });
    }
    Ok(identities)
}

fn duration_clusters(mut identities: Vec<ExactIdentity>) -> Vec<Vec<ExactIdentity>> {
    identities.sort_by_key(|identity| (identity.duration_ms, identity.track_id));
    let mut clusters = Vec::<Vec<ExactIdentity>>::new();
    for identity in identities {
        let append = clusters
            .last()
            .and_then(|cluster| cluster.first())
            .is_some_and(|first| identity.duration_ms - first.duration_ms <= MAX_DURATION_DELTA_MS);
        if append {
            clusters.last_mut().expect("cluster exists").push(identity);
        } else {
            clusters.push(vec![identity]);
        }
    }
    clusters
}

fn exact_group(mut identities: Vec<ExactIdentity>) -> Option<AutoTrackMergeGroup> {
    let release_tracks = identities
        .iter()
        .map(|identity| identity.release_track_id)
        .collect::<BTreeSet<_>>();
    if release_tracks.len() < 2 {
        return None;
    }
    identities.sort_by(|left, right| {
        right
            .canonical_score
            .cmp(&left.canonical_score)
            .then_with(|| left.track_id.cmp(&right.track_id))
    });
    let target = identities.first()?.clone();
    let mut source_track_ids = identities
        .iter()
        .skip(1)
        .map(|identity| identity.track_id)
        .collect::<Vec<_>>();
    source_track_ids.sort_unstable();
    let mut all_track_ids = source_track_ids.clone();
    all_track_ids.push(target.track_id);
    all_track_ids.sort_unstable();
    let group_id = format!(
        "exact:{}",
        all_track_ids
            .iter()
            .map(i64::to_string)
            .collect::<Vec<_>>()
            .join("-")
    );
    Some(AutoTrackMergeGroup {
        group_id,
        target_track_id: target.track_id,
        source_track_ids,
        title: target.title,
        artist_display: target.artist_display,
        album_title: target.album_title,
        subtitle: target.subtitle,
        year: target.year,
        disc_number: target.disc_number,
        track_number: target.track_number,
        recording_kind: target.recording_kind,
        duration_min_ms: identities
            .iter()
            .map(|identity| identity.duration_ms)
            .min()?,
        duration_max_ms: identities
            .iter()
            .map(|identity| identity.duration_ms)
            .max()?,
        track_count: identities.len() as u32,
        file_count: identities
            .iter()
            .map(|identity| identity.file_count.max(0) as u32)
            .sum(),
        media_variant_count: identities
            .iter()
            .map(|identity| identity.media_variant_count.max(0) as u32)
            .sum(),
    })
}

fn normalize_optional(value: Option<&str>) -> Option<String> {
    value
        .map(normalize_text)
        .filter(|normalized| !normalized.is_empty())
}
