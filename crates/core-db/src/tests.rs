use super::*;

async fn test_pool() -> (DbPool, PathBuf) {
    let path =
        std::env::temp_dir().join(format!("intmusic-core-db-{}.sqlite", uuid::Uuid::new_v4()));
    let pool = connect(&path).await.expect("create test database");
    migrate(&pool).await.expect("migrate test database");
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
            INSERT INTO library_roots (id, path, enabled, created_at, updated_at)
            VALUES (1, '/music', 1, ?1, ?1)
            "#,
    )
    .bind(&now)
    .execute(&pool)
    .await
    .expect("insert root");
    for id in 1_i64..=3 {
        sqlx::query(
            r#"
                INSERT INTO files (
                    id, library_root_id, path, relative_path, extension,
                    size_bytes, modified_at, scan_status, created_at, updated_at
                )
                VALUES (?1, 1, ?2, ?3, 'flac', 1024, ?4, 'ready', ?4, ?4)
                "#,
        )
        .bind(id)
        .bind(format!("/music/{id}.flac"))
        .bind(format!("{id}.flac"))
        .bind(&now)
        .execute(&pool)
        .await
        .expect("insert file");
        sqlx::query(
            r#"
                INSERT INTO tracks (id, file_id, title, duration_ms, created_at, updated_at)
                VALUES (?1, ?1, ?2, 180000, ?3, ?3)
                "#,
        )
        .bind(id)
        .bind(format!("Track {id}"))
        .bind(&now)
        .execute(&pool)
        .await
        .expect("insert track");
    }
    (pool, path)
}

async fn close_test_pool(pool: DbPool, path: PathBuf) {
    pool.close().await;
    let _ = tokio::fs::remove_file(&path).await;
    let _ = tokio::fs::remove_file(path.with_extension("sqlite-shm")).await;
    let _ = tokio::fs::remove_file(path.with_extension("sqlite-wal")).await;
}

#[tokio::test]
async fn client_sync_identity_and_cursor_are_durable() {
    let (pool, path) = test_pool().await;
    let first_server_id = sync_server_id(&pool).await.expect("server ID");
    assert_eq!(
        sync_server_id(&pool).await.expect("stable server ID"),
        first_server_id
    );
    let baseline = sync_cursor(&pool).await.expect("baseline cursor");
    assert!(baseline > 0);
    let first = append_sync_change(&pool, "tracks", "favorite updated")
        .await
        .expect("first change");
    let second = append_sync_change(&pool, "artists", "profile updated")
        .await
        .expect("second change");
    assert!(first > baseline);
    assert!(second > first);
    let changes = client_sync_changes(&pool, first, 50)
        .await
        .expect("changes after cursor");
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].cursor, second);
    assert_eq!(changes[0].scope, "artists");
    close_test_pool(pool, path).await;
}

async fn ingest_test_track(pool: &DbPool, filename: &str, album: &str, title: &str) -> i64 {
    let now = Utc::now().to_rfc3339();
    let file = FileIngest {
        library_root_id: 1,
        path: format!("/music/{filename}"),
        relative_path: filename.to_string(),
        extension: "flac".to_string(),
        size_bytes: 10_000,
        modified_at: now,
        quick_hash: Some(format!("quick-{filename}")),
        scan_status: "ok".to_string(),
        scan_message: None,
        codec: Some("flac".to_string()),
        sample_rate: Some(96_000),
        channels: Some(2),
        duration_ms: Some(240_000),
        bitrate: Some(2_400_000),
        bit_depth: Some(24),
    };
    let metadata = TrackIngest {
        title: title.to_string(),
        album: Some(album.to_string()),
        track_artists: vec!["Artist".to_string()],
        album_artists: vec!["Artist".to_string()],
        disc_number: Some(1),
        track_number: Some(1),
        duration_ms: Some(240_000),
        year: Some(2020),
        ..Default::default()
    };
    let file_id = upsert_scanned_file(pool, &file, Some(&metadata))
        .await
        .expect("ingest track");
    track_id_for_file(pool, file_id)
        .await
        .expect("find track")
        .expect("track exists")
}

#[tokio::test]
async fn release_tracks_remain_in_each_album_when_recordings_are_related() {
    let (pool, path) = test_pool().await;
    let original_track_id =
        ingest_test_track(&pool, "original.flac", "Original Album", "Shared Song").await;
    let compilation_track_id =
        ingest_test_track(&pool, "compilation.flac", "Compilation", "Shared Song").await;

    let original = track_media_profile(&pool, original_track_id)
        .await
        .expect("load original media")
        .expect("original media exists");
    let compilation = track_media_profile(&pool, compilation_track_id)
        .await
        .expect("load compilation media")
        .expect("compilation media exists");
    assert_ne!(original.release_track_id, compilation.release_track_id);
    assert_ne!(original.recording.id, compilation.recording.id);
    assert_eq!(original.variants.len(), 1);
    assert_eq!(original.variants[0].replicas.len(), 1);
    assert_eq!(original.variants[0].replicas[0].device_name, "Core local");

    let candidates = recording_link_candidates(&pool, compilation_track_id, 10)
        .await
        .expect("load candidates");
    let original_candidate = candidates
        .iter()
        .find(|candidate| candidate.track_id == original_track_id)
        .expect("original is a candidate");
    assert!(original_candidate.confidence >= 0.9);
    assert!(!original_candidate.already_linked);

    // Confirming that both release tracks use the same recording changes only
    // their relationship; neither album row nor either release-track slot is
    // removed.
    let linked = link_track_to_recording(&pool, compilation_track_id, original_track_id)
        .await
        .expect("relate recording");
    assert_eq!(linked.recording.id, original.recording.id);
    assert_eq!(linked.related_release_tracks.len(), 2);

    let related = track_media_profile(&pool, original_track_id)
        .await
        .expect("reload related media")
        .expect("related media exists");
    assert_eq!(related.related_release_tracks.len(), 2);

    let original_album = album_detail(&pool, original.release.expect("release").album_id.unwrap())
        .await
        .expect("original album");
    let compilation_album = album_detail(
        &pool,
        compilation.release.expect("release").album_id.unwrap(),
    )
    .await
    .expect("compilation album");
    assert_eq!(original_album.tracks.len(), 1);
    assert_eq!(compilation_album.tracks.len(), 1);
    assert_eq!(original_album.tracks[0].id, original_track_id);
    assert_eq!(compilation_album.tracks[0].id, compilation_track_id);

    // A confirmed relationship remains shared after rescanning either file.
    ingest_test_track(&pool, "compilation.flac", "Compilation", "Shared Song").await;
    let rescanned = track_media_profile(&pool, compilation_track_id)
        .await
        .expect("load rescanned media")
        .expect("rescanned media exists");
    assert_eq!(rescanned.recording.id, original.recording.id);
    assert_eq!(rescanned.related_release_tracks.len(), 2);

    let detached = detach_track_recording(&pool, compilation_track_id)
        .await
        .expect("detach recording");
    assert_ne!(detached.recording.id, original.recording.id);
    assert_eq!(detached.related_release_tracks.len(), 1);
    let original_after_detach = track_media_profile(&pool, original_track_id)
        .await
        .expect("reload original")
        .expect("original exists");
    assert_eq!(original_after_detach.related_release_tracks.len(), 1);

    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn queue_mutations_keep_current_track_and_revision() {
    let (pool, path) = test_pool().await;
    let queue = replace_playback_queue(
        &pool,
        "zone-a",
        ReplacePlaybackQueue {
            track_ids: vec![1, 2, 3],
            start_index: Some(1),
            mode: Some(PlaybackMode::Sequential),
        },
    )
    .await
    .expect("replace queue");
    assert_eq!(queue.items.len(), 3);
    assert_eq!(queue.current_index, Some(1));
    assert_eq!(queue.items[1].track.id, 2);

    let moved = move_playback_queue_item(&pool, "zone-a", 1, 0)
        .await
        .expect("move queue item");
    assert!(moved.revision > queue.revision);
    assert_eq!(moved.items[0].track.id, 2);
    assert_eq!(moved.current_index, Some(0));

    let removed = remove_playback_queue_item(&pool, "zone-a", moved.items[2].id)
        .await
        .expect("remove queue item");
    assert_eq!(removed.items.len(), 2);
    assert_eq!(removed.items[0].track.id, 2);
    assert_eq!(removed.current_index, Some(0));

    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn stepping_and_volume_follow_persisted_zone_preferences() {
    let (pool, path) = test_pool().await;
    replace_playback_queue(
        &pool,
        "zone-b",
        ReplacePlaybackQueue {
            track_ids: vec![1, 2, 3],
            start_index: Some(0),
            mode: Some(PlaybackMode::RepeatAll),
        },
    )
    .await
    .expect("replace queue");

    let previous = step_playback_queue(&pool, "zone-b", true, false)
        .await
        .expect("step previous")
        .expect("repeat all wraps");
    assert_eq!(previous, 3);
    let next = step_playback_queue(&pool, "zone-b", false, false)
        .await
        .expect("step next")
        .expect("repeat all wraps forward");
    assert_eq!(next, 1);

    let volume = set_zone_volume(&pool, "zone-b", VolumeControlMode::Player, 1.7, Some(false))
        .await
        .expect("set volume");
    assert_eq!(volume.volume, 1.0);
    assert!(!volume.muted);
    let persisted = zone_volume(&pool, "zone-b").await.expect("get volume");
    assert_eq!(persisted.volume, 1.0);
    assert!(!persisted.muted);

    let system = set_zone_system_volume_state(&pool, "zone-b", 0.35, true)
        .await
        .expect("report system volume");
    assert_eq!(system.mode, VolumeControlMode::Player);
    assert_eq!(system.volume, 1.0);
    assert_eq!(system.system_volume, Some(0.35));
    assert_eq!(system.system_muted, Some(true));

    let selected = set_zone_volume(&pool, "zone-b", VolumeControlMode::System, 0.35, Some(true))
        .await
        .expect("select system volume");
    assert_eq!(selected.mode, VolumeControlMode::System);
    assert_eq!(selected.volume, 0.35);
    assert!(selected.muted);
    assert_eq!(selected.player_volume, 1.0);
    assert!(!selected.player_muted);

    let muted_zero = set_zone_system_volume_state(&pool, "zone-b", 0.0, true)
        .await
        .expect("report an endpoint that exposes mute as zero volume");
    assert_eq!(muted_zero.volume, 0.35);
    assert_eq!(muted_zero.system_volume, Some(0.35));
    assert!(muted_zero.muted);

    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn repairs_migration_checksums_changed_only_by_line_endings() {
    let path =
        std::env::temp_dir().join(format!("intmusic-core-db-{}.sqlite", uuid::Uuid::new_v4()));
    let pool = connect(&path).await.expect("create test database");
    migrate(&pool).await.expect("migrate test database");

    let migration = MIGRATOR
        .iter()
        .find(|migration| migration.version == 1)
        .expect("initial migration");
    let alternate_checksum = connection::migration_line_ending_checksums(&migration.sql)
        .into_iter()
        .find(|checksum| checksum.as_slice() != migration.checksum.as_ref())
        .expect("alternate line-ending checksum");
    sqlx::query("UPDATE _sqlx_migrations SET checksum = ?1 WHERE version = 1")
        .bind(&alternate_checksum)
        .execute(&pool)
        .await
        .expect("replace migration checksum");

    migrate(&pool)
        .await
        .expect("repair line-ending migration checksum");

    let repaired_checksum: Vec<u8> =
        sqlx::query_scalar("SELECT checksum FROM _sqlx_migrations WHERE version = 1")
            .fetch_one(&pool)
            .await
            .expect("load repaired checksum");
    assert_eq!(repaired_checksum.as_slice(), migration.checksum.as_ref());

    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn rejects_genuinely_modified_migration_checksums() {
    let path =
        std::env::temp_dir().join(format!("intmusic-core-db-{}.sqlite", uuid::Uuid::new_v4()));
    let pool = connect(&path).await.expect("create test database");
    migrate(&pool).await.expect("migrate test database");

    sqlx::query("UPDATE _sqlx_migrations SET checksum = zeroblob(48) WHERE version = 1")
        .execute(&pool)
        .await
        .expect("replace migration checksum");

    let error = migrate(&pool)
        .await
        .expect_err("a genuinely different checksum must still fail");
    assert!(error
        .to_string()
        .contains("failed to run database migrations"));

    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn artist_profiles_and_five_region_visuals_round_trip() {
    let (pool, path) = test_pool().await;
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        r#"
            INSERT INTO artists (
                id, name, sort_name, normalized_name, created_at, updated_at
            )
            VALUES (1, 'Local Artist', NULL, 'local artist', ?1, ?1)
            "#,
    )
    .bind(&now)
    .execute(&pool)
    .await
    .expect("insert artist");

    update_artist_profile(
        &pool,
        1,
        &UpdateArtistProfile {
            display_name: Some("Display Artist".to_string()),
            musicbrainz_id: Some("20244d07-534f-4eff-b4d4-930878889970".to_string()),
            genres: vec!["Pop".to_string()],
            ..UpdateArtistProfile::default()
        },
    )
    .await
    .expect("save profile");
    let asset = add_artist_asset(
        &pool,
        1,
        NewArtistAsset {
            sha256: "test-sha",
            original_filename: "artist.png",
            storage_path: "/tmp/artist.png",
            mime_type: "image/png",
            width: 1000,
            height: 1000,
            byte_size: 1024,
            photo_type: "portrait",
        },
    )
    .await
    .expect("save asset");
    let regions = (0_u8..5)
        .map(|position| ArtistVisualRegion {
            position,
            asset_id: asset.id,
            crop_x: 0.0,
            crop_y: 0.0,
            crop_width: 1.0,
            crop_height: 1.0,
            focal_x: 0.5,
            focal_y: 0.5,
        })
        .collect::<Vec<_>>();
    let visual = save_artist_visual(
        &pool,
        1,
        "avatar",
        &UpdateArtistVisual {
            asset_id: Some(asset.id),
            template: "feature".to_string(),
            fit: "cover".to_string(),
            focal_x: 0.5,
            focal_y: 0.5,
            blur: 0.0,
            brightness: 1.0,
            regions: regions.clone(),
        },
    )
    .await
    .expect("save five-region visual");
    assert_eq!(visual.regions.len(), 5);

    let mut six_regions = regions;
    six_regions.push(ArtistVisualRegion {
        position: 5,
        asset_id: asset.id,
        crop_x: 0.0,
        crop_y: 0.0,
        crop_width: 1.0,
        crop_height: 1.0,
        focal_x: 0.5,
        focal_y: 0.5,
    });
    let error = save_artist_visual(
        &pool,
        1,
        "avatar",
        &UpdateArtistVisual {
            asset_id: Some(asset.id),
            template: "feature".to_string(),
            fit: "cover".to_string(),
            focal_x: 0.5,
            focal_y: 0.5,
            blur: 0.0,
            brightness: 1.0,
            regions: six_regions,
        },
    )
    .await
    .expect_err("sixth region must be rejected");
    assert!(error.to_string().contains("at most 5"));

    let detail = artist_detail(&pool, 1).await.expect("load artist detail");
    assert_eq!(detail.artist.name, "Display Artist");
    assert!(detail.artist.has_artwork);
    assert_eq!(detail.profile.genres, vec!["Pop"]);
    assert_eq!(detail.visuals[0].regions.len(), 5);

    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn manual_track_metadata_and_lyrics_survive_rescan() {
    let (pool, path) = test_pool().await;
    let file = FileIngest {
        library_root_id: 1,
        path: "/music/1.flac".to_string(),
        relative_path: "1.flac".to_string(),
        extension: "flac".to_string(),
        size_bytes: 1024,
        modified_at: Utc::now().to_rfc3339(),
        quick_hash: None,
        scan_status: "ok".to_string(),
        scan_message: None,
        codec: Some("flac".to_string()),
        sample_rate: Some(48_000),
        channels: Some(2),
        duration_ms: Some(180_000),
        bitrate: None,
        bit_depth: Some(24),
    };
    let mut scanned = TrackIngest {
        title: "File title".to_string(),
        album: Some("File album".to_string()),
        track_artists: vec!["File artist".to_string()],
        genres: vec!["Pop".to_string()],
        lyrics: Some("[00:01.00]file lyric".to_string()),
        lyrics_kind: Some("lrc".to_string()),
        ..Default::default()
    };
    upsert_scanned_file(&pool, &file, Some(&scanned))
        .await
        .expect("initial scan");

    let initial = track_edit_snapshot(&pool, 1)
        .await
        .expect("initial edit snapshot");
    let update = TrackMetadataUpdate {
        expected_revision: Some(initial.revision),
        fields: vec![
            protocol::TrackMetadataFieldUpdate {
                key: "title".to_string(),
                value: Value::String("Manual title".to_string()),
            },
            protocol::TrackMetadataFieldUpdate {
                key: "genres".to_string(),
                value: serde_json::json!(["Art Pop", "Live"]),
            },
        ],
        lyrics: Some(protocol::TrackLyricsUpdate {
            kind: "lrc".to_string(),
            text: "[00:02.00]manual lyric".to_string(),
            language: Some("en".to_string()),
            translation: Some("[00:02.00]人工翻译".to_string()),
            pronunciation: None,
            offset_ms: 25,
        }),
        ..Default::default()
    };
    let edited = update_track_metadata(
        &pool,
        1,
        &update,
        Some(&[protocol::LyricCue {
            start_ms: 2_025,
            text: "manual lyric".to_string(),
            ..Default::default()
        }]),
    )
    .await
    .expect("edit metadata");
    assert_eq!(edited.detail.track.title, "Manual title");
    assert_eq!(edited.detail.genres, vec!["Art Pop", "Live"]);

    scanned.title = "New file title".to_string();
    scanned.genres = vec!["Rock".to_string()];
    scanned.lyrics = Some("[00:03.00]new file lyric".to_string());
    upsert_scanned_file(&pool, &file, Some(&scanned))
        .await
        .expect("rescan");

    let after_rescan = track_edit_snapshot(&pool, 1)
        .await
        .expect("snapshot after rescan");
    assert_eq!(after_rescan.detail.track.title, "Manual title");
    assert_eq!(after_rescan.detail.genres, vec!["Art Pop", "Live"]);
    assert_eq!(
        after_rescan.detail.lyrics.as_ref().unwrap().text,
        "[00:02.00]manual lyric"
    );
    let title = after_rescan
        .fields
        .iter()
        .find(|field| field.key == "title")
        .unwrap();
    assert_eq!(
        title.file_value,
        Value::String("New file title".to_string())
    );
    assert_eq!(title.source, "manual");

    let reverted = update_track_metadata(
        &pool,
        1,
        &TrackMetadataUpdate {
            expected_revision: Some(after_rescan.revision),
            clear_fields: vec!["title".to_string()],
            ..Default::default()
        },
        None,
    )
    .await
    .expect("revert title");
    assert_eq!(reverted.detail.track.title, "New file title");

    let restored_lyrics = update_track_metadata(
        &pool,
        1,
        &TrackMetadataUpdate {
            expected_revision: Some(reverted.revision),
            clear_lyrics_override: true,
            ..Default::default()
        },
        None,
    )
    .await
    .expect("restore file lyrics");
    assert_eq!(
        restored_lyrics.detail.lyrics.as_ref().unwrap().text,
        "[00:03.00]new file lyric"
    );
    assert_eq!(
        restored_lyrics.detail.lyrics.as_ref().unwrap().source,
        "file"
    );

    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn client_manifests_aggregate_exact_copies_and_reconcile_missing_files() {
    let (pool, path) = test_pool().await;
    let make_manifest =
        |device_id: &str, root_id: &str, scan_id: &str, complete: bool, include_file: bool| {
            ClientLibraryManifestRequest {
                device_id: device_id.to_string(),
                device_name: format!("{device_id} player"),
                platform: Some("test".to_string()),
                root: protocol::ClientLibraryRootManifest {
                    external_id: root_id.to_string(),
                    display_name: format!("{device_id} music"),
                    path_hint: Some(format!("/{device_id}/music")),
                },
                scan_id: scan_id.to_string(),
                complete,
                files: if include_file {
                    vec![protocol::ClientLibraryFileManifest {
                        external_id: "album/01-song.flac".to_string(),
                        relative_path: "album/01-song.flac".to_string(),
                        extension: "flac".to_string(),
                        size_bytes: 4_096,
                        modified_at: Utc::now(),
                        quick_hash: Some("same-sampled-content".to_string()),
                        content_hash: None,
                        codec: Some("flac".to_string()),
                        sample_rate: Some(96_000),
                        channels: Some(2),
                        duration_ms: Some(180_000),
                        bitrate: Some(2_400_000),
                        bit_depth: Some(24),
                        metadata: ClientTrackManifest {
                            title: "Song".to_string(),
                            album: Some("Album".to_string()),
                            track_artists: vec!["Artist".to_string()],
                            album_artists: vec!["Artist".to_string()],
                            track_number: Some(1),
                            duration_ms: Some(180_000),
                            ..Default::default()
                        },
                    }]
                } else {
                    Vec::new()
                },
            }
        };

    let first =
        upsert_client_library_manifest(&pool, &make_manifest("dev-a", "root-a", "a1", true, true))
            .await
            .expect("upload first client manifest");
    assert_eq!(first.accepted_files, 1);
    assert_eq!(first.missing_files, 0);
    assert_eq!(first.bindings.len(), 1);

    let tracks_after_first = list_tracks(&pool, 100, 0).await.expect("list tracks");
    assert_eq!(tracks_after_first.len(), 4);
    let client_track_id = tracks_after_first
        .iter()
        .find(|track| track.title == "Song")
        .expect("client track")
        .id;
    assert_eq!(first.bindings[0].track_id, client_track_id);

    upsert_client_library_manifest(&pool, &make_manifest("dev-b", "root-b", "b0", true, false))
        .await
        .expect("register empty destination client root");
    let relayed_distribution = create_distribution_job(
        &pool,
        &protocol::CreateDistributionRequest {
            target_device_id: "dev-b".to_string(),
            target_root_external_id: "root-b".to_string(),
            quality: "original".to_string(),
            track_ids: vec![client_track_id],
            ..Default::default()
        },
    )
    .await
    .expect("create Client-sourced distribution");
    assert_eq!(relayed_distribution.state, "awaiting_source");
    assert!(claim_distribution_source_task(&pool, "dev-b")
        .await
        .expect("query wrong source client")
        .is_none());
    let source_task = claim_distribution_source_task(&pool, "dev-a")
        .await
        .expect("claim source upload")
        .expect("Client source task");
    assert_eq!(source_task.track_id, client_track_id);
    assert_eq!(source_task.source_root_external_id, "root-a");
    assert_eq!(source_task.source_relative_path, "album/01-song.flac");
    assert_eq!(source_task.expected_size_bytes, 4_096);
    let relayed = complete_distribution_source_task(
        &pool,
        &source_task.id,
        "dev-a",
        Path::new("/cache/client-source.flac"),
        4_096,
        "same-sampled-content",
    )
    .await
    .expect("complete Client source upload");
    assert_eq!(relayed.state, "queued");
    let relayed_delivery = claim_distribution_task(&pool, "dev-b")
        .await
        .expect("claim relayed delivery")
        .expect("relayed destination task");
    let relayed_source = distribution_content_source(&pool, &relayed_delivery.id, "dev-b")
        .await
        .expect("relayed content source");
    assert_eq!(relayed_source.path, "/cache/client-source.flac");
    update_distribution_task(
        &pool,
        &relayed_delivery.id,
        &protocol::DistributionTaskProgress {
            device_id: "dev-b".to_string(),
            state: "completed".to_string(),
            transferred_bytes: 4_096,
            retryable: false,
            error: None,
        },
    )
    .await
    .expect("complete relayed delivery");

    upsert_scanned_file(
        &pool,
        &FileIngest {
            library_root_id: 1,
            path: "/music/1.flac".to_string(),
            relative_path: "1.flac".to_string(),
            extension: "flac".to_string(),
            size_bytes: 1024,
            modified_at: Utc::now().to_rfc3339(),
            quick_hash: Some("core-track-1".to_string()),
            scan_status: "ready".to_string(),
            scan_message: None,
            codec: Some("flac".to_string()),
            sample_rate: Some(48_000),
            channels: Some(2),
            duration_ms: Some(180_000),
            bitrate: Some(1_000_000),
            bit_depth: Some(24),
        },
        Some(&TrackIngest {
            title: "Track 1".to_string(),
            ..Default::default()
        }),
    )
    .await
    .expect("normalize Core source track");
    let distribution = create_distribution_job(
        &pool,
        &protocol::CreateDistributionRequest {
            target_device_id: "dev-a".to_string(),
            target_root_external_id: "root-a".to_string(),
            quality: "original".to_string(),
            track_ids: vec![1],
            ..Default::default()
        },
    )
    .await
    .expect("create distribution");
    assert_eq!(distribution.total_items, 1);
    assert_eq!(distribution.state, "queued");
    let task = claim_distribution_task(&pool, "dev-a")
        .await
        .expect("claim distribution")
        .expect("pending distribution task");
    assert_eq!(task.track_id, 1);
    assert!(task.relative_path.ends_with(".flac"));
    let source = distribution_content_source(&pool, &task.id, "dev-a")
        .await
        .expect("distribution source");
    assert_eq!(source.extension, "flac");
    let completed = update_distribution_task(
        &pool,
        &task.id,
        &protocol::DistributionTaskProgress {
            device_id: "dev-a".to_string(),
            state: "completed".to_string(),
            transferred_bytes: task.expected_size_bytes,
            retryable: false,
            error: None,
        },
    )
    .await
    .expect("complete distribution");
    assert_eq!(completed.state, "completed");
    assert_eq!(completed.completed_items, 1);
    assert!(claim_distribution_task(&pool, "dev-a")
        .await
        .expect("claim after completion")
        .is_none());
    let transcoded_distribution = create_distribution_job(
        &pool,
        &protocol::CreateDistributionRequest {
            target_device_id: "dev-a".to_string(),
            target_root_external_id: "root-a".to_string(),
            quality: "aac-256".to_string(),
            track_ids: vec![1],
            ..Default::default()
        },
    )
    .await
    .expect("create transcoded distribution");
    assert_eq!(transcoded_distribution.state, "preparing");
    assert_eq!(transcoded_distribution.total_bytes, 0);
    let transcode_task = claim_distribution_transcode_task(&pool)
        .await
        .expect("claim transcode")
        .expect("pending transcode");
    assert_eq!(transcode_task.quality, "aac-256");
    let prepared = complete_distribution_transcode_task(
        &pool,
        &transcode_task.id,
        Path::new("/cache/transcoded.m4a"),
        "m4a",
        512,
        "transcoded-hash",
    )
    .await
    .expect("complete transcode");
    assert_eq!(prepared.state, "queued");
    assert_eq!(prepared.total_bytes, 512);
    let delivery = claim_distribution_task(&pool, "dev-a")
        .await
        .expect("claim transcoded delivery")
        .expect("transcoded delivery");
    assert_eq!(delivery.extension, "m4a");
    assert_eq!(delivery.expected_size_bytes, 512);
    assert_eq!(
        delivery.expected_quick_hash.as_deref(),
        Some("transcoded-hash")
    );
    let failed_distribution = create_distribution_job(
        &pool,
        &protocol::CreateDistributionRequest {
            target_device_id: "dev-a".to_string(),
            target_root_external_id: "root-a".to_string(),
            quality: "aac-96".to_string(),
            track_ids: vec![1],
            ..Default::default()
        },
    )
    .await
    .expect("create failing transcode distribution");
    let failed_task = claim_distribution_transcode_task(&pool)
        .await
        .expect("claim failing transcode")
        .expect("failing transcode task");
    let failed =
        fail_distribution_transcode_task(&pool, &failed_task.id, false, "test transcode failure")
            .await
            .expect("record terminal transcode failure");
    assert_eq!(failed.id, failed_distribution.id);
    assert_eq!(failed.state, "completed_with_errors");
    assert_eq!(failed.failed_items, 1);
    assert_eq!(failed.error.as_deref(), Some("test transcode failure"));
    assert!(create_distribution_job(
        &pool,
        &protocol::CreateDistributionRequest {
            target_device_id: "dev-a".to_string(),
            target_root_external_id: "root-a".to_string(),
            quality: "arbitrary-shell-arguments".to_string(),
            track_ids: vec![1],
            ..Default::default()
        },
    )
    .await
    .expect_err("unknown transcoding profile must fail")
    .to_string()
    .contains("unknown distribution quality profile"));

    let mutation_request = protocol::ClientMutationBatchRequest {
        device_id: "dev-a".to_string(),
        device_name: "Device A".to_string(),
        platform: Some("test".to_string()),
        mutations: vec![
            protocol::ClientMutation {
                id: "favorite-1".to_string(),
                kind: "favorite".to_string(),
                track_id: client_track_id,
                occurred_at: Utc::now(),
                payload: serde_json::json!({"is_favorite": true}),
            },
            protocol::ClientMutation {
                id: "playback-1".to_string(),
                kind: "playback".to_string(),
                track_id: client_track_id,
                occurred_at: Utc::now(),
                payload: serde_json::json!({
                    "started_at": Utc::now().to_rfc3339(),
                    "ended_at": Utc::now().to_rfc3339(),
                    "start_position_ms": 0,
                    "end_position_ms": 120_000,
                    "reason": "completed"
                }),
            },
        ],
    };
    let applied = apply_client_mutations(&pool, &mutation_request)
        .await
        .expect("apply offline mutations");
    assert_eq!(applied.applied_ids.len(), 2);
    let duplicate = apply_client_mutations(&pool, &mutation_request)
        .await
        .expect("reapply offline mutations");
    assert_eq!(duplicate.duplicate_ids.len(), 2);
    assert!(
        track_detail(&pool, client_track_id)
            .await
            .expect("favorite detail")
            .track
            .is_favorite
    );
    assert_eq!(
        list_playback_sessions(&pool, 20, 0, None, None)
            .await
            .expect("offline playback sessions")
            .into_iter()
            .filter(|session| session.track_id == client_track_id)
            .count(),
        1,
        "idempotent replay must create exactly one playback session"
    );

    upsert_client_library_manifest(&pool, &make_manifest("dev-b", "root-b", "b1", true, true))
        .await
        .expect("upload exact copy from second client");
    let tracks_after_second = list_tracks(&pool, 100, 0).await.expect("list tracks");
    assert_eq!(
        tracks_after_second.len(),
        4,
        "an exact copy must add a replica, not a duplicate catalog track"
    );
    let media = track_media_profile(&pool, client_track_id)
        .await
        .expect("load media")
        .expect("media profile");
    assert_eq!(media.variants.len(), 1);
    assert_eq!(media.variants[0].replicas.len(), 2);
    assert!(media.variants[0]
        .replicas
        .iter()
        .any(|replica| replica.device_id.as_deref() == Some("dev-a")
            && replica.root_external_id.as_deref() == Some("root-a")));
    assert!(media.variants[0]
        .replicas
        .iter()
        .any(|replica| replica.device_id.as_deref() == Some("dev-b")
            && replica.root_external_id.as_deref() == Some("root-b")));
    let replica = media.variants[0]
        .replicas
        .iter()
        .find(|replica| replica.device_id.as_deref() == Some("dev-a"))
        .expect("client replica metadata");
    assert_eq!(replica.extension.as_deref(), Some("flac"));
    assert_eq!(replica.size_bytes, Some(4_096));
    assert_eq!(replica.codec.as_deref(), Some("flac"));
    assert_eq!(replica.bitrate, Some(2_400_000));
    assert_eq!(replica.sample_rate, Some(96_000));
    assert_eq!(replica.bit_depth, Some(24));
    assert_eq!(replica.channels, Some(2));
    assert!(replica.modified_at.is_some());

    let reconciled =
        upsert_client_library_manifest(&pool, &make_manifest("dev-a", "root-a", "a2", true, false))
            .await
            .expect("reconcile removed file");
    assert_eq!(reconciled.missing_files, 1);
    let media = track_media_profile(&pool, client_track_id)
        .await
        .expect("load reconciled media")
        .expect("media profile");
    assert!(media.variants[0].replicas.iter().any(|replica| {
        replica.device_id.as_deref() == Some("dev-a") && replica.availability_state == "missing"
    }));
    assert!(media.variants[0].replicas.iter().any(|replica| {
        replica.device_id.as_deref() == Some("dev-b") && replica.availability_state == "ready"
    }));

    remove_client_library_root(&pool, "dev-b", "root-b")
        .await
        .expect("remove second client root");
    let statuses = list_client_library_roots(&pool)
        .await
        .expect("list client roots");
    assert_eq!(statuses.len(), 2);
    assert_eq!(
        list_library_roots(&pool)
            .await
            .expect("list core roots")
            .len(),
        1,
        "client-owned roots must not leak into Core scan settings"
    );

    close_test_pool(pool, path).await;
}
