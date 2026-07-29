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
