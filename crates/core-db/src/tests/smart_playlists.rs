use super::*;

fn source_manifest(
    device_id: &str,
    root_external_id: &str,
    title: &str,
) -> ClientLibraryManifestRequest {
    ClientLibraryManifestRequest {
        device_id: device_id.to_string(),
        device_name: device_id.to_string(),
        platform: Some("android".to_string()),
        root: protocol::ClientLibraryRootManifest {
            external_id: root_external_id.to_string(),
            display_name: root_external_id.to_string(),
            path_hint: Some(format!("/music/{root_external_id}")),
        },
        scan_id: Uuid::now_v7().to_string(),
        complete: false,
        files: vec![protocol::ClientLibraryFileManifest {
            external_id: format!("{title}.flac"),
            relative_path: format!("{title}.flac"),
            extension: "flac".to_string(),
            size_bytes: 1_000,
            modified_at: Utc::now(),
            quick_hash: Some(format!("quick-{device_id}-{title}")),
            content_hash: None,
            codec: Some("flac".to_string()),
            sample_rate: Some(48_000),
            channels: Some(2),
            duration_ms: Some(180_000),
            bitrate: Some(1_000_000),
            bit_depth: Some(16),
            metadata_status: "ready".to_string(),
            metadata_message: None,
            metadata_source: Some("embedded_tag".to_string()),
            metadata: ClientTrackManifest {
                title: title.to_string(),
                album: Some("Source album".to_string()),
                track_artists: vec!["Source artist".to_string()],
                album_artists: vec!["Source artist".to_string()],
                duration_ms: Some(180_000),
                ..Default::default()
            },
        }],
    }
}

#[tokio::test]
async fn smart_playlist_source_rules_use_active_replica_sources() {
    let (pool, path) = test_pool().await;
    let source_a = upsert_client_library_manifest(
        &pool,
        &source_manifest("source-client-a", "source-a", "Source song"),
    )
    .await
    .expect("ingest first source");
    let source_b = upsert_client_library_manifest(
        &pool,
        &source_manifest("source-client-b", "source-b", "Other song"),
    )
    .await
    .expect("ingest second source");

    let in_a = serde_json::json!({
        "match": "all",
        "rules": [{
            "field": "library_source",
            "op": "in_any",
            "value": [source_a.root_id]
        }]
    });
    let tracks = smart_playlist_tracks(&pool, Some(&in_a), 100, 0, true)
        .await
        .expect("evaluate source smart playlist");
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].title, "Source song");

    let not_in_b = serde_json::json!({
        "rules": [{
            "field": "library_source",
            "op": "not_in",
            "value": [source_b.root_id]
        }]
    });
    let tracks = smart_playlist_tracks(&pool, Some(&not_in_b), 100, 0, true)
        .await
        .expect("evaluate excluded source");
    assert!(tracks.iter().any(|track| track.title == "Source song"));
    assert!(tracks.iter().all(|track| track.title != "Other song"));

    manage_library_source(&pool, source_a.root_id, "remove")
        .await
        .expect("remove selected source");
    let tracks = smart_playlist_tracks(&pool, Some(&in_a), 100, 0, true)
        .await
        .expect("re-evaluate removed source");
    assert!(
        tracks.is_empty(),
        "removed sources must stop matching smart playlists"
    );

    close_test_pool(pool, path).await;
}
