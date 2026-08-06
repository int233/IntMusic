use super::*;

#[tokio::test]
async fn untagged_client_files_wait_for_manual_resolution_without_path_inference() {
    let (pool, path) = test_pool().await;
    let manifest =
        |external_id: &str, quick_hash: &str, size_bytes: i64| ClientLibraryManifestRequest {
            device_id: "android-client".to_string(),
            device_name: "Android player".to_string(),
            platform: Some("android".to_string()),
            root: protocol::ClientLibraryRootManifest {
                external_id: "phone-music".to_string(),
                display_name: "Phone music".to_string(),
                path_hint: Some("/storage/emulated/0/Music".to_string()),
            },
            scan_id: Uuid::now_v7().to_string(),
            complete: false,
            files: vec![protocol::ClientLibraryFileManifest {
                external_id: external_id.to_string(),
                relative_path: external_id.to_string(),
                extension: "flac".to_string(),
                size_bytes,
                modified_at: Utc::now(),
                quick_hash: Some(quick_hash.to_string()),
                content_hash: None,
                codec: Some("flac".to_string()),
                sample_rate: Some(48_000),
                channels: Some(2),
                duration_ms: Some(200_000),
                bitrate: Some(1_500_000),
                bit_depth: Some(24),
                metadata_status: "needs_attention".to_string(),
                metadata_message: Some(
                    "Missing required embedded TITLE and ARTIST tags".to_string(),
                ),
                metadata_source: Some("embedded_tag".to_string()),
                metadata: ClientTrackManifest::default(),
            }],
        };

    let first = upsert_client_library_manifest(
        &pool,
        &manifest("Artist/Album/guessed-title.flac", "untagged-a", 10_000),
    )
    .await
    .expect("upload untagged client file");
    assert!(first.bindings.is_empty());
    assert_eq!(
        list_tracks(&pool, 100, 0).await.expect("list tracks").len(),
        3,
        "a filename and its parent folders must not create catalog identity"
    );
    let pending = list_client_library_pending_files(&pool)
        .await
        .expect("list pending files");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].scan_status, "needs_attention");

    let manual = ClientTrackManifest {
        title: "Confirmed title".to_string(),
        album: Some("Confirmed album".to_string()),
        track_artists: vec!["Confirmed artist".to_string()],
        album_artists: vec!["Confirmed artist".to_string()],
        ..Default::default()
    };
    let created =
        resolve_client_library_file(&pool, pending[0].file_id, "metadata", None, Some(&manual))
            .await
            .expect("create track from confirmed metadata");
    assert_eq!(created.scan_status, "ok");
    let target_track_id = created.track_id.expect("created track id");
    assert!(list_client_library_pending_files(&pool)
        .await
        .expect("pending after metadata")
        .is_empty());

    upsert_client_library_manifest(
        &pool,
        &manifest("Unknown/second-copy.flac", "different-encoding", 12_000),
    )
    .await
    .expect("upload second untagged client file");
    let pending = list_client_library_pending_files(&pool)
        .await
        .expect("list second pending file");
    assert_eq!(pending.len(), 1);
    let matched = resolve_client_library_file(
        &pool,
        pending[0].file_id,
        "match",
        Some(target_track_id),
        None,
    )
    .await
    .expect("match untagged file to known track");
    assert_eq!(matched.scan_status, "identified");
    let media = track_media_profile(&pool, target_track_id)
        .await
        .expect("load matched media")
        .expect("media profile");
    assert_eq!(
        media.variants.len(),
        2,
        "different file bytes must become another media variant of the same release track"
    );

    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn rescanning_a_linked_client_copy_reuses_its_existing_replica() {
    let (pool, path) = test_pool().await;
    let target_track_id =
        ingest_test_track(&pool, "shared-copy.flac", "Shared album", "Shared track").await;
    let manifest = |scan_id: &str| ClientLibraryManifestRequest {
        device_id: "android-client".to_string(),
        device_name: "Android player".to_string(),
        platform: Some("android".to_string()),
        root: protocol::ClientLibraryRootManifest {
            external_id: "phone-music".to_string(),
            display_name: "Phone music".to_string(),
            path_hint: Some("/storage/emulated/0/Music".to_string()),
        },
        scan_id: scan_id.to_string(),
        complete: false,
        files: vec![protocol::ClientLibraryFileManifest {
            external_id: "shared-copy".to_string(),
            relative_path: "Shared/shared-copy.flac".to_string(),
            extension: "flac".to_string(),
            size_bytes: 10_000,
            modified_at: Utc::now(),
            quick_hash: Some("quick-shared-copy.flac".to_string()),
            content_hash: None,
            codec: Some("flac".to_string()),
            sample_rate: Some(96_000),
            channels: Some(2),
            duration_ms: Some(240_000),
            bitrate: Some(2_400_000),
            bit_depth: Some(24),
            metadata_status: "ready".to_string(),
            metadata_message: None,
            metadata_source: Some("embedded_tag".to_string()),
            metadata: ClientTrackManifest {
                title: "Shared track".to_string(),
                album: Some("Shared album".to_string()),
                track_artists: vec!["Artist".to_string()],
                album_artists: vec!["Artist".to_string()],
                duration_ms: Some(240_000),
                ..Default::default()
            },
        }],
    };

    let first = upsert_client_library_manifest(&pool, &manifest("scan-1"))
        .await
        .expect("ingest an exact client copy");
    assert_eq!(first.bindings.len(), 1);
    assert_eq!(first.bindings[0].track_id, target_track_id);

    let client_file_id: i64 = sqlx::query_scalar(
        r#"
        SELECT file.id
        FROM files file
        JOIN library_roots root ON root.id = file.library_root_id
        WHERE root.owner_device_id = 'android-client'
          AND file.client_file_id = 'shared-copy'
        "#,
    )
    .fetch_one(&pool)
    .await
    .expect("find client copy");
    assert!(
        track_id_for_file(&pool, client_file_id)
            .await
            .expect("check direct track")
            .is_none(),
        "an exact physical copy must reuse the catalog track instead of creating another one"
    );

    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
        UPDATE files
        SET deleted_at = ?1, availability_state = 'missing'
        WHERE id = (SELECT file_id FROM tracks WHERE id = ?2)
        "#,
    )
    .bind(&now)
    .bind(target_track_id)
    .execute(&pool)
    .await
    .expect("make the original physical copy unavailable");

    let stale_track_id =
        ingest_test_track(&pool, "stale-retry.flac", "Shared album", "Shared track").await;
    sqlx::query("UPDATE tracks SET file_id = ?1 WHERE id = ?2")
        .bind(client_file_id)
        .bind(stale_track_id)
        .execute(&pool)
        .await
        .expect("simulate a partially committed retry");
    sqlx::query(
        r#"
        INSERT INTO playback_events (
            zone_id, event_type, track_id, track_title, created_at
        )
        VALUES ('stale-zone', 'play', ?1, 'Shared track', ?2)
        "#,
    )
    .bind(stale_track_id)
    .bind(Utc::now().to_rfc3339())
    .execute(&pool)
    .await
    .expect("retain a historical reference to the stale track");

    let rescanned = upsert_client_library_manifest(&pool, &manifest("scan-2"))
        .await
        .expect("rescan must reuse the linked client replica");
    assert_eq!(rescanned.bindings.len(), 1);
    assert_eq!(rescanned.bindings[0].track_id, target_track_id);
    assert_eq!(
        rescanned.bindings[0].media_variant_id,
        first.bindings[0].media_variant_id
    );
    assert_eq!(
        track_id_for_file(&pool, client_file_id)
            .await
            .expect("check rescanned direct track"),
        Some(stale_track_id),
        "the legacy row must remain available to historical foreign keys"
    );
    let stale_track_exists: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM tracks WHERE id = ?1")
        .bind(stale_track_id)
        .fetch_one(&pool)
        .await
        .expect("check stale retry track");
    assert_eq!(
        stale_track_exists, 1,
        "referenced legacy track rows must not be deleted during reconciliation"
    );
    let canonical_track_id: Option<i64> = sqlx::query_scalar(
        "SELECT canonical_track_id FROM track_merge_members WHERE track_id = ?1",
    )
    .bind(stale_track_id)
    .fetch_optional(&pool)
    .await
    .expect("check canonicalized retry track");
    assert_eq!(canonical_track_id, Some(target_track_id));
    let replica_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM media_replicas WHERE file_id = ?1")
            .bind(client_file_id)
            .fetch_one(&pool)
            .await
            .expect("count physical replicas");
    assert_eq!(replica_count, 1);

    close_test_pool(pool, path).await;
}
