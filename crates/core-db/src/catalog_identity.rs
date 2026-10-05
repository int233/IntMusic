use std::collections::BTreeMap;

use super::*;

/// A release position identifies the song; year, encoding and device identify
/// descriptions/copies, not new songs. Never match on title alone.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct SongKey {
    title: String,
    artists: Vec<String>,
    album: String,
    version: String,
    disc: i64,
    position: i64,
}

struct SongSource {
    release_track_id: i64,
    recording_id: i64,
    source_recording_id: i64,
    match_kind: String,
    release_identity_id: Option<i64>,
    decision_at: i64,
    duration_ms: i64,
    year: Option<i64>,
}

/// Rebuilds song identity from the inventory, independent of scan order and
/// physical format. Ambiguous editions stay separate. No file is modified.
pub async fn reconcile_catalog_identity(pool: &DbPool) -> Result<u64> {
    let mut tx = pool.begin().await?;
    sqlx::query("UPDATE track_catalog_links SET source_recording_id = (SELECT recording_id FROM release_tracks WHERE id = release_track_id) WHERE source_recording_id IS NULL")
        .execute(&mut *tx).await?;
    let rows = sqlx::query(
        r#"
        SELECT link.release_track_id, rt.recording_id, link.source_recording_id, link.match_kind, link.release_identity_id, COALESCE(unixepoch(link.updated_at), 0) AS decision_at, t.title,
               COALESCE(t.subtitle, '') AS version, COALESCE(album.title, '') AS album,
               COALESCE(t.disc_number, 1) AS disc, t.track_number,
               t.duration_ms, t.year,
               (SELECT GROUP_CONCAT(ar.name, char(31)) FROM track_artists ta
                JOIN artists ar ON ar.id = ta.artist_id
                WHERE ta.track_id = t.id AND ta.role = 'primary') AS artists
        FROM tracks t
        JOIN track_catalog_links link ON link.track_id = t.id
        JOIN release_tracks rt ON rt.id = link.release_track_id
        LEFT JOIN albums album ON album.id = t.album_id
        WHERE NOT EXISTS (SELECT 1 FROM track_merge_members m WHERE m.track_id = t.id)
        ORDER BY t.id
    "#,
    )
    .fetch_all(&mut *tx)
    .await?;
    let mut groups = BTreeMap::<SongKey, Vec<i64>>::new();
    let mut sources_by_release = BTreeMap::new();
    let mut desired = BTreeMap::new();
    for row in rows {
        let mut artists = row
            .try_get::<Option<String>, _>("artists")?
            .unwrap_or_default()
            .split('\u{1f}')
            .map(normalize_text)
            .filter(|v| !v.is_empty())
            .collect::<Vec<_>>();
        artists.sort();
        artists.dedup();
        let key = SongKey {
            title: normalize_text(&row.try_get::<String, _>("title")?),
            artists,
            album: normalize_text(&row.try_get::<String, _>("album")?),
            version: normalize_text(&row.try_get::<String, _>("version")?),
            disc: row.try_get("disc")?,
            position: row.try_get::<Option<i64>, _>("track_number")?.unwrap_or(0),
        };
        let source = SongSource {
            release_track_id: row.try_get("release_track_id")?,
            recording_id: row.try_get("recording_id")?,
            source_recording_id: row.try_get("source_recording_id")?,
            match_kind: row.try_get("match_kind")?,
            release_identity_id: row.try_get("release_identity_id")?,
            decision_at: row.try_get("decision_at")?,
            duration_ms: row.try_get::<Option<i64>, _>("duration_ms")?.unwrap_or(0),
            year: row
                .try_get::<Option<i64>, _>("year")?
                .filter(|year| *year > 0),
        };
        let explicit = matches!(
            source.match_kind.as_str(),
            "confirmed_recording" | "detached"
        );
        desired.insert(
            source.release_track_id,
            (
                if explicit {
                    source.recording_id
                } else {
                    source.source_recording_id
                },
                source.release_track_id,
                false,
            ),
        );
        if !key.title.is_empty()
            && !key.artists.is_empty()
            && !key.album.is_empty()
            && key.position > 0
            && source.duration_ms > 0
        {
            groups.entry(key).or_default().push(source.release_track_id);
        }
        sources_by_release.insert(source.release_track_id, source);
    }
    let mut changed = 0;
    for ids in groups.values() {
        let sources = ids
            .iter()
            .map(|id| &sources_by_release[id])
            .collect::<Vec<_>>();
        // Bound the entire duration range; pairwise chaining merges editions.
        let years = sources
            .iter()
            .filter_map(|s| s.year)
            .collect::<HashSet<_>>();
        let min = sources.iter().map(|s| s.duration_ms).min().unwrap_or(0);
        let max = sources.iter().map(|s| s.duration_ms).max().unwrap_or(0);
        if sources.len() < 2 || years.len() > 1 || max - min > 2_000 {
            continue;
        }
        // Association applies to the whole album edition. Old clients changed
        // only one encoding copy; the most recent explicit decision governs it.
        let canonical = sources
            .iter()
            .filter(|s| matches!(s.match_kind.as_str(), "confirmed_recording" | "detached"))
            .max_by_key(|s| (s.decision_at, s.release_track_id))
            .map(|s| s.recording_id)
            .unwrap_or_else(|| sources.iter().map(|s| s.source_recording_id).min().unwrap());
        let release_identity = *ids.iter().min().unwrap();
        for source in sources {
            desired.insert(source.release_track_id, (canonical, release_identity, true));
        }
    }
    for (id, (recording, release_identity, shared)) in desired {
        let source = &sources_by_release[&id];
        // The original per-source identity makes metadata corrections reversible.
        if source.recording_id != recording {
            sqlx::query("UPDATE release_tracks SET recording_id = ?1 WHERE id = ?2")
                .bind(recording)
                .bind(id)
                .execute(&mut *tx)
                .await?;
            sqlx::query(
                r#"UPDATE audio_masters SET recording_id = ?1 WHERE id IN (
                SELECT v.audio_master_id FROM release_track_media_variants r
                JOIN media_variants v ON v.id = r.media_variant_id WHERE r.release_track_id = ?2
            )"#,
            )
            .bind(recording)
            .bind(id)
            .execute(&mut *tx)
            .await?;
            changed += 1;
        }
        if source.release_identity_id != Some(release_identity) {
            sqlx::query("UPDATE track_catalog_links SET release_identity_id = ?1 WHERE release_track_id = ?2")
                .bind(release_identity).bind(id).execute(&mut *tx).await?;
            changed += 1;
        }
        let kind = if matches!(
            source.match_kind.as_str(),
            "confirmed_recording" | "detached"
        ) {
            source.match_kind.as_str()
        } else if shared {
            "catalog_identity"
        } else {
            "file_seed"
        };
        if source.match_kind != kind {
            sqlx::query(
                "UPDATE track_catalog_links SET match_kind = ?1 WHERE release_track_id = ?2",
            )
            .bind(kind)
            .bind(id)
            .execute(&mut *tx)
            .await?;
        }
    }
    if changed > 0 {
        sqlx::query("INSERT INTO client_sync_changes (scope, reason, created_at) VALUES ('library', 'song identities reconciled', datetime('now'))")
            .execute(&mut *tx).await?;
    }
    tx.commit().await?;
    Ok(changed)
}

#[derive(Debug, Clone)]
pub struct TrackSourceCandidate {
    pub file_id: i64,
    pub path: String,
    pub extension: String,
}

/// All eligible Core copies for this song, from the same identity graph used by
/// the library UI. Client shadow URIs are never filesystem/HTTP stream sources.
pub async fn track_source_candidates(
    pool: &DbPool,
    track_id: i64,
) -> Result<Vec<TrackSourceCandidate>> {
    let rows = sqlx::query(
        r#"
        SELECT DISTINCT f.id, f.path, f.extension
        FROM track_catalog_links target
        JOIN track_catalog_links edition_link
          ON COALESCE(edition_link.release_identity_id, edition_link.release_track_id)
           = COALESCE(target.release_identity_id, target.release_track_id)
        JOIN release_tracks edition ON edition.id = edition_link.release_track_id
        JOIN release_track_media_variants binding ON binding.release_track_id = edition.id
        JOIN media_replicas replica ON replica.media_variant_id = binding.media_variant_id
        JOIN files f ON f.id = replica.file_id
        JOIN library_roots root ON root.id = f.library_root_id
        WHERE target.track_id = ?1 AND replica.source_kind = 'core'
          AND replica.availability_state = 'ready' AND f.deleted_at IS NULL
          AND f.availability_state = 'ready' AND root.enabled = 1
          AND root.retired_at IS NULL AND root.removed_at IS NULL
          AND f.path NOT LIKE 'intmusic-client://%'
        ORDER BY f.id
    "#,
    )
    .bind(track_id)
    .fetch_all(pool)
    .await?;
    rows.into_iter()
        .map(|row| {
            Ok(TrackSourceCandidate {
                file_id: row.try_get("id")?,
                path: row.try_get("path")?,
                extension: row.try_get("extension")?,
            })
        })
        .collect()
}
