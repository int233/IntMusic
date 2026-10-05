use super::*;

async fn recording(pool: &DbPool, track: i64) -> i64 {
    track_media_profile(pool, track)
        .await
        .unwrap()
        .unwrap()
        .recording
        .id
}

#[tokio::test]
async fn transcoded_phone_copy_without_year_joins_core_song_and_bindings() {
    let (pool, path) = test_pool().await;
    let core = ingest_test_track(&pool, "original.flac", "我与你", "只想一生跟你走").await;
    let result = upsert_client_library_manifest(
        &pool,
        &ClientLibraryManifestRequest {
            device_id: "mate80".into(),
            device_name: "Mate80".into(),
            platform: Some("android".into()),
            root: protocol::ClientLibraryRootManifest {
                external_id: "music".into(),
                display_name: "Music".into(),
                path_hint: None,
            },
            scan_id: "one".into(),
            batch_id: Some("one".into()),
            complete: true,
            files: vec![protocol::ClientLibraryFileManifest {
                external_id: "song.m4a".into(),
                relative_path: "02 - 只想一生跟你走.m4a".into(),
                extension: "m4a".into(),
                size_bytes: 7000,
                modified_at: Utc::now(),
                quick_hash: Some("different-transcode-bytes".into()),
                content_hash: None,
                codec: Some("aac".into()),
                sample_rate: Some(44100),
                channels: Some(2),
                duration_ms: Some(240000),
                bitrate: Some(256000),
                bit_depth: None,
                metadata_status: "ready".into(),
                metadata_message: None,
                metadata_source: Some("embedded_tag".into()),
                metadata: ClientTrackManifest {
                    title: "只想一生跟你走".into(),
                    album: Some("我与你".into()),
                    track_artists: vec!["Artist".into()],
                    album_artists: vec!["Artist".into()],
                    track_number: Some(1),
                    duration_ms: Some(240000),
                    ..Default::default()
                },
            }],
        },
    )
    .await
    .unwrap();
    assert_eq!(result.bindings[0].track_id, core);
    let bindings = client_library_copy_bindings(&pool, "mate80").await.unwrap();
    assert_eq!(bindings[0].track_id, core);
    let profile = track_media_profile(&pool, core).await.unwrap().unwrap();
    assert_eq!(profile.variants.len(), 2);
    assert!(profile
        .variants
        .iter()
        .flat_map(|v| &v.replicas)
        .any(|r| r.source_kind == "core"));
    assert!(profile
        .variants
        .iter()
        .flat_map(|v| &v.replicas)
        .any(|r| r.device_id.as_deref() == Some("mate80")));
    let songs = list_tracks(&pool, 100, 0).await.unwrap();
    assert_eq!(
        songs.iter().filter(|t| t.title == "只想一生跟你走").count(),
        1
    );
    assert_eq!(track_source_candidates(&pool, core).await.unwrap().len(), 1);
    assert_eq!(reconcile_catalog_identity(&pool).await.unwrap(), 0);
    sqlx::query("UPDATE files SET deleted_at = 'removed' WHERE id = (SELECT file_id FROM tracks WHERE id = ?1)")
        .bind(core).execute(&pool).await.unwrap();
    let visible = list_tracks(&pool, 100, 0)
        .await
        .unwrap()
        .into_iter()
        .find(|track| track.title == "只想一生跟你走")
        .unwrap();
    assert_ne!(visible.id, core);
    assert_eq!(
        client_library_copy_bindings(&pool, "mate80").await.unwrap()[0].track_id,
        visible.id
    );

    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn identity_rebuild_reverses_a_match_after_metadata_correction() {
    let (pool, path) = test_pool().await;
    let first = ingest_test_track(&pool, "a.flac", "Album", "Song").await;
    let second = ingest_test_track(&pool, "b.m4a", "Album", "Song").await;
    reconcile_catalog_identity(&pool).await.unwrap();
    assert_eq!(
        recording(&pool, first).await,
        recording(&pool, second).await
    );
    sqlx::query("UPDATE tracks SET subtitle = 'Live' WHERE id = ?1")
        .bind(second)
        .execute(&pool)
        .await
        .unwrap();
    reconcile_catalog_identity(&pool).await.unwrap();
    assert_ne!(
        recording(&pool, first).await,
        recording(&pool, second).await
    );
    assert_eq!(
        track_source_candidates(&pool, second).await.unwrap().len(),
        1
    );
    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn uncertain_versions_editions_and_positions_remain_separate() {
    let (pool, path) = test_pool().await;
    let first = ingest_test_track(&pool, "base.flac", "Album", "Song").await;
    for (index, update) in [
        "subtitle = 'Live'",
        "year = 2022",
        "track_number = 2",
        "duration_ms = 246000",
    ]
    .iter()
    .enumerate()
    {
        let candidate = ingest_test_track(&pool, &format!("{index}.flac"), "Album", "Song").await;
        sqlx::query(&format!("UPDATE tracks SET {update} WHERE id = ?1"))
            .bind(candidate)
            .execute(&pool)
            .await
            .unwrap();
        reconcile_catalog_identity(&pool).await.unwrap();
        assert_ne!(
            recording(&pool, first).await,
            recording(&pool, candidate).await
        );
    }
    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn removed_core_copy_and_client_shadow_uri_are_never_stream_sources() {
    let (pool, path) = test_pool().await;
    let first = ingest_test_track(&pool, "one.flac", "Album", "Song").await;
    let second = ingest_test_track(&pool, "two.flac", "Album", "Song").await;
    reconcile_catalog_identity(&pool).await.unwrap();
    assert_eq!(
        track_source_candidates(&pool, first).await.unwrap().len(),
        2
    );
    sqlx::query("UPDATE files SET deleted_at = 'removed' WHERE id = (SELECT file_id FROM tracks WHERE id = ?1)").bind(first).execute(&pool).await.unwrap();
    let sources = track_source_candidates(&pool, first).await.unwrap();
    assert_eq!(sources.len(), 1);
    assert!(sources[0].path.ends_with("two.flac"));
    assert_eq!(
        library_counts(&pool).await.unwrap().tracks as usize,
        list_tracks(&pool, 100, 0).await.unwrap().len()
    );
    assert_eq!(
        list_tracks(&pool, 100, 0)
            .await
            .unwrap()
            .iter()
            .map(|t| t.id)
            .filter(|id| *id == first || *id == second)
            .collect::<Vec<_>>(),
        vec![second]
    );
    assert_eq!(
        client_sync_detail_ids(&pool, "track", 0, 100)
            .await
            .unwrap()
            .into_iter()
            .filter(|id| *id == first || *id == second)
            .collect::<Vec<_>>(),
        vec![second]
    );

    sqlx::query("UPDATE files SET path = 'intmusic-client://phone/song' WHERE id = (SELECT file_id FROM tracks WHERE id = ?1)").bind(second).execute(&pool).await.unwrap();
    assert!(track_source_candidates(&pool, first)
        .await
        .unwrap()
        .is_empty());
    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn linked_albums_keep_their_own_sources_and_detach_all_encoding_copies() {
    let (pool, path) = test_pool().await;
    let lover = ingest_test_track(&pool, "lover.flac", "Lover", "Cruel Summer").await;
    let phone = ingest_test_track(&pool, "lover.m4a", "Lover", "Cruel Summer").await;
    let tour = ingest_test_track(&pool, "tour.flac", "The Eras Tour", "Cruel Summer").await;
    reconcile_catalog_identity(&pool).await.unwrap();
    let profile = link_track_to_recording(&pool, lover, tour).await.unwrap();
    assert_eq!(recording(&pool, lover).await, recording(&pool, phone).await);
    assert_eq!(profile.related_release_tracks.len(), 3);
    assert_eq!(
        profile
            .related_release_tracks
            .iter()
            .map(|r| r.release_identity_id)
            .collect::<HashSet<_>>()
            .len(),
        2
    );
    assert_eq!(
        list_tracks(&pool, 100, 0)
            .await
            .unwrap()
            .iter()
            .filter(|t| t.title == "Cruel Summer")
            .count(),
        2
    );
    let artist_id: i64 =
        sqlx::query_scalar("SELECT artist_id FROM track_artists WHERE track_id = ?1 LIMIT 1")
            .bind(lover)
            .fetch_one(&pool)
            .await
            .unwrap();
    let artist = artist_detail(&pool, artist_id).await.unwrap();
    assert_eq!(
        artist
            .tracks
            .iter()
            .filter(|t| t.title == "Cruel Summer")
            .count(),
        2
    );
    let found = search_tracks(&pool, "Cruel Summer", 100).await.unwrap();
    assert_eq!(found.len(), 2);
    assert!(found.iter().any(|t| t.id == lover));
    assert!(found.iter().any(|t| t.id == tour));
    let lover_sources = track_source_candidates(&pool, lover).await.unwrap();
    assert_eq!(lover_sources.len(), 2);
    assert!(lover_sources.iter().all(|s| s.path.contains("lover.")));
    let tour_sources = track_source_candidates(&pool, tour).await.unwrap();
    assert_eq!(tour_sources.len(), 1);
    assert!(tour_sources[0].path.ends_with("tour.flac"));
    let tour_profile = track_media_profile(&pool, tour).await.unwrap().unwrap();
    let tour_variant = tour_profile
        .variants
        .iter()
        .find(|v| v.release_track_ids.contains(&tour_profile.release_track_id))
        .unwrap();
    assert_eq!(
        crate::client_file_resolution::canonical_track_id_for_media_variant(&pool, tour_variant.id)
            .await
            .unwrap(),
        Some(tour)
    );
    let detached = detach_track_recording(&pool, lover).await.unwrap();
    assert_eq!(detached.related_release_tracks.len(), 2);
    let identity = recording(&pool, lover).await;
    assert_eq!(identity, recording(&pool, phone).await);
    assert_ne!(identity, recording(&pool, tour).await);
    reconcile_catalog_identity(&pool).await.unwrap();
    assert_eq!(
        identity,
        recording(&pool, lover).await,
        "a later scan must preserve separation"
    );
    let newcomer = ingest_test_track(&pool, "lover-new.aac", "Lover", "Cruel Summer").await;
    reconcile_catalog_identity(&pool).await.unwrap();
    assert_eq!(identity, recording(&pool, newcomer).await);
    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn latest_album_association_repairs_old_per_copy_decisions() {
    let (pool, path) = test_pool().await;
    let lover = ingest_test_track(&pool, "lover.flac", "Lover", "Cruel Summer").await;
    let phone = ingest_test_track(&pool, "lover.m4a", "Lover", "Cruel Summer").await;
    let tour = ingest_test_track(&pool, "tour.flac", "The Eras Tour", "Cruel Summer").await;
    reconcile_catalog_identity(&pool).await.unwrap();
    let target = recording(&pool, tour).await;
    // Reproduce the old API: a previous phone association and a newer Core-only association.
    sqlx::query("UPDATE track_catalog_links SET match_kind = 'confirmed_recording', updated_at = '2026-08-01T00:00:00Z' WHERE track_id = ?1")
        .bind(phone).execute(&pool).await.unwrap();
    sqlx::query("UPDATE tracks SET year = NULL WHERE id = ?1")
        .bind(phone)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("UPDATE release_tracks SET recording_id = ?1 WHERE id = (SELECT release_track_id FROM track_catalog_links WHERE track_id = ?2)")
        .bind(target).bind(lover).execute(&pool).await.unwrap();
    sqlx::query("UPDATE track_catalog_links SET match_kind = 'confirmed_recording', updated_at = '2026-10-04T00:00:00Z' WHERE track_id = ?1")
        .bind(lover).execute(&pool).await.unwrap();
    reconcile_catalog_identity(&pool).await.unwrap();
    assert_eq!(recording(&pool, phone).await, target);
    let sources = track_source_candidates(&pool, phone).await.unwrap();
    assert_eq!(sources.len(), 2);
    assert!(sources.iter().all(|s| s.path.contains("lover.")));
    assert_eq!(reconcile_catalog_identity(&pool).await.unwrap(), 0);
    close_test_pool(pool, path).await;
}
