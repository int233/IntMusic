use super::*;

pub(super) fn source_manifest(
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
        batch_id: None,
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
