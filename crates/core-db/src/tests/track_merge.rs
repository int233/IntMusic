use std::collections::BTreeSet;

use super::*;

#[tokio::test]
async fn confirmed_file_merge_is_folded_and_reversible() {
    let (pool, path) = test_pool().await;
    let source_track_id =
        ingest_test_track(&pool, "source.flac", "Shared album", "Shared song").await;
    let target_track_id =
        ingest_test_track(&pool, "target.mp3", "Shared album", "Shared song").await;
    let source_file_id: i64 = sqlx::query_scalar("SELECT file_id FROM tracks WHERE id = ?1")
        .bind(source_track_id)
        .fetch_one(&pool)
        .await
        .expect("source file");
    let target_file_id: i64 = sqlx::query_scalar("SELECT file_id FROM tracks WHERE id = ?1")
        .bind(target_track_id)
        .fetch_one(&pool)
        .await
        .expect("target file");

    let preview = preview_track_merge(
        &pool,
        &[source_file_id, target_file_id],
        Some(target_track_id),
    )
    .await
    .expect("preview compatible files");
    assert!(preview.can_merge);
    assert_eq!(preview.source_track_ids, vec![source_track_id]);

    let before = list_tracks(&pool, 100, 0).await.expect("songs before");
    let result = merge_tracks(
        &pool,
        &TrackMergeRequest {
            target_track_id,
            source_track_ids: vec![source_track_id],
            confirm_conflicts: false,
        },
    )
    .await
    .expect("merge physical files");
    assert_eq!(result.merged_tracks, 1);
    assert_eq!(result.linked_media_variants, 1);

    let after = list_tracks(&pool, 100, 0).await.expect("songs after");
    assert_eq!(after.len() + 1, before.len());
    assert!(after.iter().any(|track| track.id == target_track_id));
    assert!(after.iter().all(|track| track.id != source_track_id));
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM tracks WHERE id = ?1")
            .bind(source_track_id)
            .fetch_one(&pool)
            .await
            .expect("source legacy row"),
        1,
        "merge must not delete the compatibility row"
    );

    let media = track_media_profile(&pool, target_track_id)
        .await
        .expect("target media")
        .expect("target profile");
    assert_eq!(media.variants.len(), 2);
    let album_id = media.release.as_ref().and_then(|release| release.album_id);
    let album = album_detail(&pool, album_id.expect("album id"))
        .await
        .expect("album after merge");
    assert_eq!(
        album
            .tracks
            .iter()
            .filter(|track| track.title == "Shared song")
            .count(),
        1
    );
    assert!(album.tracks.iter().any(|track| track.id == target_track_id));
    sqlx::query("UPDATE files SET deleted_at = ?1 WHERE id = ?2")
        .bind(Utc::now().to_rfc3339())
        .bind(target_file_id)
        .execute(&pool)
        .await
        .expect("mark canonical file unavailable");
    let (fallback_path, _) = track_stream_source(&pool, target_track_id)
        .await
        .expect("select another core replica");
    assert!(fallback_path.ends_with("source.flac"));

    let undone = undo_track_merge(&pool, &result.merge_id)
        .await
        .expect("undo merge");
    assert_eq!(undone.state, "undone");
    let restored = list_tracks(&pool, 100, 0).await.expect("songs restored");
    assert_eq!(restored.len(), before.len());
    let album = album_detail(&pool, album_id.expect("album id"))
        .await
        .expect("album after undo");
    assert_eq!(
        album
            .tracks
            .iter()
            .filter(|track| track.title == "Shared song")
            .count(),
        2
    );

    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn different_releases_are_not_offered_as_physical_file_merge() {
    let (pool, path) = test_pool().await;
    let first = ingest_test_track(&pool, "album.flac", "Studio album", "Same title").await;
    let second = ingest_test_track(&pool, "live.flac", "Live album", "Same title").await;
    let first_file: i64 = sqlx::query_scalar("SELECT file_id FROM tracks WHERE id = ?1")
        .bind(first)
        .fetch_one(&pool)
        .await
        .expect("first file");
    let second_file: i64 = sqlx::query_scalar("SELECT file_id FROM tracks WHERE id = ?1")
        .bind(second)
        .fetch_one(&pool)
        .await
        .expect("second file");

    let preview = preview_track_merge(&pool, &[first_file, second_file], Some(first))
        .await
        .expect("preview different releases");
    assert!(!preview.can_merge);
    assert!(preview
        .conflicts
        .iter()
        .any(|conflict| conflict.field == "album" && conflict.severity == "error"));
    let automatic = preview_exact_track_merges(&pool, Some(100))
        .await
        .expect("scan exact duplicates");
    assert!(
        automatic.groups.is_empty(),
        "same title and artist on different albums must remain separate release tracks"
    );

    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn exact_duplicate_scan_previews_and_merges_device_or_encoding_copies() {
    let (pool, path) = test_pool().await;
    let first = ingest_test_track(&pool, "copy.flac", "Exact album", "Exact song").await;
    let second = ingest_test_track(&pool, "copy.mp3", "Exact album", "Exact song").await;
    let second_file: i64 = sqlx::query_scalar("SELECT file_id FROM tracks WHERE id = ?1")
        .bind(second)
        .fetch_one(&pool)
        .await
        .expect("second file");
    sqlx::query(
        "UPDATE files SET extension = 'mp3', codec = 'mp3', bitrate = 320000, duration_ms = duration_ms + 1500 WHERE id = ?1",
    )
    .bind(second_file)
    .execute(&pool)
    .await
    .expect("make a distinct encoding");
    sqlx::query("UPDATE tracks SET duration_ms = duration_ms + 1500 WHERE id = ?1")
        .bind(second)
        .execute(&pool)
        .await
        .expect("allow a small encoding duration difference");

    let preview = preview_exact_track_merges(&pool, Some(100))
        .await
        .expect("preview exact copies");
    assert_eq!(preview.duplicate_groups, 1);
    assert_eq!(preview.duplicate_tracks, 2);
    assert_eq!(preview.physical_files, 2);
    let group = preview.groups.first().expect("duplicate group");
    let members = std::iter::once(group.target_track_id)
        .chain(group.source_track_ids.iter().copied())
        .collect::<BTreeSet<_>>();
    assert_eq!(members, BTreeSet::from([first, second]));

    let merged = merge_exact_track_groups(
        &pool,
        &AutoTrackMergeRequest {
            group_ids: vec![group.group_id.clone()],
        },
    )
    .await
    .expect("merge exact copies");
    assert_eq!(merged.merged_groups, 1);
    assert_eq!(merged.merged_tracks, 1);
    assert!(merged.failures.is_empty());
    assert_eq!(
        list_tracks(&pool, 100, 0)
            .await
            .expect("folded songs")
            .iter()
            .filter(|track| track.title == "Exact song")
            .count(),
        1
    );
    assert!(preview_exact_track_merges(&pool, Some(100))
        .await
        .expect("rescan exact copies")
        .groups
        .is_empty());

    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn exact_duplicate_scan_rejects_version_position_and_duration_differences() {
    let (pool, path) = test_pool().await;
    let baseline = ingest_test_track(&pool, "baseline.flac", "Album", "Song").await;
    let version = ingest_test_track(&pool, "version.flac", "Album", "Song").await;
    let position = ingest_test_track(&pool, "position.flac", "Album", "Song").await;
    let duration = ingest_test_track(&pool, "duration.flac", "Album", "Song").await;
    let year = ingest_test_track(&pool, "year.flac", "Album", "Song").await;
    sqlx::query("UPDATE tracks SET subtitle = 'Live' WHERE id = ?1")
        .bind(version)
        .execute(&pool)
        .await
        .expect("set version");
    sqlx::query("UPDATE tracks SET track_number = 2 WHERE id = ?1")
        .bind(position)
        .execute(&pool)
        .await
        .expect("set position");
    sqlx::query("UPDATE tracks SET duration_ms = duration_ms + 3000 WHERE id = ?1")
        .bind(duration)
        .execute(&pool)
        .await
        .expect("set duration");
    sqlx::query("UPDATE tracks SET year = year + 1 WHERE id = ?1")
        .bind(year)
        .execute(&pool)
        .await
        .expect("set year");

    let preview = preview_exact_track_merges(&pool, Some(100))
        .await
        .expect("scan guarded duplicates");
    assert!(preview.groups.is_empty());
    assert!(preview
        .groups
        .iter()
        .all(|group| group.target_track_id != baseline));

    close_test_pool(pool, path).await;
}
