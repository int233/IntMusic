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

    close_test_pool(pool, path).await;
}
