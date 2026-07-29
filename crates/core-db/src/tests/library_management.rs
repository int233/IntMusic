use super::*;

fn client_manifest(
    device_id: &str,
    root_id: &str,
    file_name: &str,
    metadata_status: &str,
    metadata: ClientTrackManifest,
) -> ClientLibraryManifestRequest {
    ClientLibraryManifestRequest {
        device_id: device_id.to_string(),
        device_name: "Living room client".to_string(),
        platform: Some("android".to_string()),
        root: protocol::ClientLibraryRootManifest {
            external_id: root_id.to_string(),
            display_name: "Phone music".to_string(),
            path_hint: Some("/storage/emulated/0/Music".to_string()),
        },
        scan_id: Uuid::now_v7().to_string(),
        complete: false,
        files: vec![protocol::ClientLibraryFileManifest {
            external_id: file_name.to_string(),
            relative_path: file_name.to_string(),
            extension: "flac".to_string(),
            size_bytes: 24_000_000,
            modified_at: Utc::now(),
            quick_hash: Some(format!("quick-{file_name}")),
            content_hash: None,
            codec: Some("flac".to_string()),
            sample_rate: Some(96_000),
            channels: Some(2),
            duration_ms: Some(240_000),
            bitrate: Some(2_400_000),
            bit_depth: Some(24),
            metadata_status: metadata_status.to_string(),
            metadata_message: (metadata_status != "ready")
                .then(|| "Missing required embedded TITLE and ARTIST tags".to_string()),
            metadata_source: Some("embedded_tag".to_string()),
            metadata,
        }],
    }
}

#[tokio::test]
async fn inventory_lists_every_file_and_surfaces_untagged_client_files() {
    let (pool, path) = test_pool().await;
    upsert_client_library_manifest(
        &pool,
        &client_manifest(
            "android-client",
            "phone-music",
            "Unsorted/mystery.flac",
            "needs_attention",
            ClientTrackManifest::default(),
        ),
    )
    .await
    .expect("ingest untagged client file");

    let all = list_library_files(
        &pool,
        &LibraryFileQuery {
            limit: 100,
            ..Default::default()
        },
    )
    .await
    .expect("list complete inventory");
    assert_eq!(all.total, 4, "three Core files and one Client file");
    let client_file = all
        .items
        .iter()
        .find(|file| file.device_id == "android-client")
        .expect("client file remains visible");
    assert_eq!(client_file.identity_state, "unresolved");
    assert_eq!(client_file.metadata_state, "missing_required");
    assert_eq!(client_file.relative_path, "Unsorted/mystery.flac");

    let attention = list_library_files(
        &pool,
        &LibraryFileQuery {
            status: Some("attention".to_string()),
            limit: 100,
            ..Default::default()
        },
    )
    .await
    .expect("list attention filter");
    assert_eq!(attention.total, 1);
    assert_eq!(attention.items[0].file_id, client_file.file_id);

    let pending = list_client_library_pending_files(&pool)
        .await
        .expect("legacy pending API uses persistent issues");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].file_id, client_file.file_id);

    let summary = library_management_summary(&pool)
        .await
        .expect("load management summary");
    assert_eq!(summary.total_files, 4);
    assert_eq!(summary.attention_files, 1);
    assert_eq!(summary.device_count, 2);

    manage_library_file(&pool, client_file.file_id, "ignore")
        .await
        .expect("ignore unresolved file");
    let ignored = library_file_detail(&pool, client_file.file_id)
        .await
        .expect("load ignored file");
    assert_eq!(ignored.file.metadata_state, "ignored");
    manage_library_file(&pool, client_file.file_id, "reset")
        .await
        .expect("stop ignoring file");
    let reset = library_file_detail(&pool, client_file.file_id)
        .await
        .expect("load reset file");
    assert_eq!(reset.file.metadata_state, "missing_required");

    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn offline_and_retired_devices_keep_their_sources_and_files_manageable() {
    let (pool, path) = test_pool().await;
    let metadata = ClientTrackManifest {
        title: "Local copy".to_string(),
        album: Some("Portable album".to_string()),
        track_artists: vec!["Portable artist".to_string()],
        album_artists: vec!["Portable artist".to_string()],
        duration_ms: Some(240_000),
        ..Default::default()
    };
    upsert_client_library_manifest(
        &pool,
        &client_manifest(
            "retained-client",
            "portable-root",
            "copy.flac",
            "ready",
            metadata,
        ),
    )
    .await
    .expect("ingest client file");

    let devices = list_library_devices(&pool)
        .await
        .expect("list devices before retirement");
    let device = devices
        .iter()
        .find(|device| device.device_id == "retained-client")
        .expect("registered client");
    assert_eq!(device.sources.len(), 1);
    let root_id = device.sources[0].root_id;

    manage_library_device(&pool, "retained-client", "retire")
        .await
        .expect("retire device");
    let devices = list_library_devices(&pool)
        .await
        .expect("list retired devices");
    let retired = devices
        .iter()
        .find(|device| device.device_id == "retained-client")
        .expect("retired device is retained");
    assert_eq!(retired.state, "retired");
    assert_eq!(retired.sources[0].state, "retired");

    let files = list_library_files(
        &pool,
        &LibraryFileQuery {
            device_id: Some("retained-client".to_string()),
            status: Some("retired".to_string()),
            limit: 100,
            ..Default::default()
        },
    )
    .await
    .expect("list files from retired device");
    assert_eq!(files.total, 1);
    assert_eq!(files.items[0].presence_state, "retired");

    manage_library_device(&pool, "retained-client", "restore")
        .await
        .expect("restore device");
    manage_library_source(&pool, root_id, "retire")
        .await
        .expect("retire only the source");
    let devices = list_library_devices(&pool)
        .await
        .expect("list source lifecycle");
    let restored = devices
        .iter()
        .find(|device| device.device_id == "retained-client")
        .expect("restored device");
    assert_ne!(restored.state, "retired");
    assert_eq!(restored.sources[0].state, "retired");

    manage_library_source(&pool, root_id, "restore")
        .await
        .expect("restore source");
    let detail = library_file_detail(&pool, files.items[0].file_id)
        .await
        .expect("file remains addressable after lifecycle changes");
    assert_eq!(detail.file.device_id, "retained-client");

    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn matching_a_legacy_catalogued_file_removes_its_placeholder_track() {
    let (pool, path) = test_pool().await;
    let target_track_id = ingest_test_track(
        &pool,
        "confirmed-target.flac",
        "Confirmed album",
        "Confirmed track",
    )
    .await;
    let metadata = ClientTrackManifest {
        title: "Old inferred identity".to_string(),
        album: Some("Folder-derived album".to_string()),
        track_artists: vec!["Unknown Artist".to_string()],
        album_artists: vec!["Unknown Artist".to_string()],
        duration_ms: Some(240_000),
        ..Default::default()
    };
    upsert_client_library_manifest(
        &pool,
        &client_manifest(
            "legacy-client",
            "legacy-root",
            "legacy.flac",
            "ready",
            metadata,
        ),
    )
    .await
    .expect("ingest legacy placeholder");
    assert_eq!(
        list_tracks(&pool, 100, 0)
            .await
            .expect("tracks before match")
            .len(),
        5
    );
    let inventory = list_library_files(
        &pool,
        &LibraryFileQuery {
            device_id: Some("legacy-client".to_string()),
            limit: 10,
            ..Default::default()
        },
    )
    .await
    .expect("legacy inventory");
    let file_id = inventory.items[0].file_id;

    resolve_client_library_file(&pool, file_id, "match", Some(target_track_id), None)
        .await
        .expect("match legacy file to known track");
    assert_eq!(
        list_tracks(&pool, 100, 0)
            .await
            .expect("tracks after match")
            .len(),
        4,
        "the old placeholder catalog row must not survive a manual match"
    );
    let detail = library_file_detail(&pool, file_id)
        .await
        .expect("matched file detail");
    assert_eq!(detail.file.track_id, Some(target_track_id));
    assert_eq!(detail.file.track_title.as_deref(), Some("Confirmed track"));

    close_test_pool(pool, path).await;
}
