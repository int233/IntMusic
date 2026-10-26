use super::*;
use protocol::{PlaybackQueueItemV3, RendererOutputRegistration};

pub(crate) async fn state() -> (AppState, PathBuf) {
    let dir = std::env::temp_dir().join(format!("intmusic-playback-test-{}", Uuid::now_v7()));
    tokio::fs::create_dir_all(&dir).await.unwrap();
    let paths = CorePaths::discover(Some(dir.join("config.toml")), Some(dir.clone())).unwrap();
    let pool = core_db::connect(&paths.database_file).await.unwrap();
    core_db::migrate(&pool).await.unwrap();
    sqlx::query("INSERT INTO library_roots (id, path, enabled, created_at, updated_at) VALUES (1, '/music', 1, 'now', 'now')").execute(&pool).await.unwrap();
    for id in 1..=3_i64 {
        sqlx::query("INSERT INTO files (id,library_root_id,path,relative_path,extension,size_bytes,modified_at,scan_status,created_at,updated_at) VALUES (?1,1,?2,?2,'flac',100,'now','ok','now','now')")
                .bind(id).bind(format!("/{id}.flac")).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO tracks (id,file_id,title,duration_ms,created_at,updated_at) VALUES (?1,?1,?2,315360,'now','now')")
                .bind(id).bind(format!("Song {id}")).execute(&pool).await.unwrap();
    }
    let transcoder = Transcoder::discover(transcoder::TranscoderSettings {
        enabled: false,
        ffmpeg_path: None,
        ffprobe_path: None,
        cache_dir: dir.join("transcode"),
        max_cache_bytes: 0,
        max_concurrent_jobs: 1,
    })
    .await;
    let state = AppState::new(
        CoreConfig::default(),
        paths,
        pool,
        (Uuid::now_v7(), "catalog".into()),
        "127.0.0.1:0".parse().unwrap(),
        None,
        transcoder,
    );
    state
        .inner
        .renderers
        .register(RendererRegistration {
            client_id: "mac".into(),
            name: "Mac".into(),
            platform: "macos".into(),
            reset_playback: false,
            request_playback_sync: false,
            outputs: ["a", "b"]
                .into_iter()
                .map(|id| RendererOutputRegistration {
                    id: id.into(),
                    name: id.into(),
                    backend: "test".into(),
                    is_default: id == "a",
                    sample_rates: vec![],
                    channels: vec![],
                    system_volume_supported: false,
                    system_volume_readable: false,
                    system_volume_writable: false,
                    system_volume_steps: None,
                    system_volume: None,
                    system_muted: None,
                })
                .collect(),
        })
        .await;
    (state, dir)
}
fn items() -> Vec<PlaybackQueueItemV3> {
    [1, 1, 2]
        .into_iter()
        .map(|track_id| PlaybackQueueItemV3 {
            item_id: Uuid::now_v7(),
            track_id,
            added_by_device_id: "mac".into(),
            added_at: Utc::now(),
        })
        .collect()
}
async fn command(
    state: &AppState,
    zone: &str,
    action: PlaybackSessionActionV3,
) -> PlaybackSessionCommandV3 {
    let current = playback_session_snapshot_v3(state, zone).await.unwrap();
    PlaybackSessionCommandV3 {
        command_id: Uuid::now_v7(),
        session_id: current.session_id,
        epoch: current.epoch,
        expected_revision: current.revision,
        origin_device_id: "mac".into(),
        issued_at: Utc::now(),
        action,
    }
}
async fn submit(
    state: &AppState,
    zone: &str,
    command: PlaybackSessionCommandV3,
) -> PlaybackCommandAckV3 {
    command_playback_session_v3(State(state.clone()), Path(zone.into()), Json(command))
        .await
        .unwrap()
        .0
}
async fn start(state: &AppState, zone: &str) -> PlaybackSessionSnapshotV3 {
    let items = items();
    let first = items[0].item_id;
    let cmd = command(
        state,
        zone,
        PlaybackSessionActionV3::ReplaceQueueAndPlay {
            source: None,
            items,
            start_item_id: first,
            position_ms: 0,
        },
    )
    .await;
    let ack = submit(state, zone, cmd).await;
    assert_eq!(ack.status, PlaybackCommandStatusV3::Applied);
    ack.snapshot.unwrap()
}
async fn cleanup(state: AppState, dir: PathBuf) {
    state.pool().close().await;
    drop(state);
    let _ = tokio::fs::remove_dir_all(dir).await;
}

#[tokio::test]
async fn system_batch_queue_keeps_source_and_rejects_expired_or_unavailable_without_clearing() {
    let (state, dir) = state().await;
    let zone = "renderer:mac:a";
    let now = Utc::now().to_rfc3339();
    sqlx::query("UPDATE files SET created_at=?1,updated_at=?1,modified_at=?1")
        .bind(&now)
        .execute(state.pool())
        .await
        .unwrap();
    sqlx::query("UPDATE tracks SET created_at=?1,updated_at=?1")
        .bind(&now)
        .execute(state.pool())
        .await
        .unwrap();
    core_db::migrate(state.pool()).await.unwrap();
    core_db::refresh_stale_collections(state.pool(), false)
        .await
        .unwrap();
    let collection_id = core_db::list_collections(state.pool())
        .await
        .unwrap()
        .into_iter()
        .find(|c| c.system_key.as_deref() == Some("daily_mix"))
        .unwrap()
        .id;
    let page = core_db::collection_page(state.pool(), collection_id, None, 0, 100)
        .await
        .unwrap();
    let plan = core_db::collection_play_plan(
        state.pool(),
        collection_id,
        &protocol::CollectionPlayRequest {
            result_version: page.result_version.clone().unwrap(),
            entity_ids: None,
        },
        false,
    )
    .await
    .unwrap();
    let source = protocol::CollectionQueueSource {
        name: "forged label".into(),
        ..plan.source
    };
    let queue: Vec<PlaybackQueueItemV3> = plan
        .tracks
        .iter()
        .map(|track| PlaybackQueueItemV3 {
            item_id: Uuid::now_v7(),
            track_id: track.id,
            added_by_device_id: "mac".into(),
            added_at: Utc::now(),
        })
        .collect();
    let action = PlaybackSessionActionV3::ReplaceQueueAndPlay {
        source: Some(source.clone()),
        items: queue.clone(),
        start_item_id: queue[1].item_id,
        position_ms: 0,
    };
    let ack = submit(&state, zone, command(&state, zone, action.clone()).await).await;
    assert_eq!(ack.status, PlaybackCommandStatusV3::Applied);
    let accepted = ack.snapshot.unwrap();
    assert_eq!(accepted.current_item_id, Some(queue[1].item_id));
    assert_eq!(accepted.queue_source.as_ref().unwrap().name, "今日随听");
    core_db::refresh_collection(
        state.pool(),
        collection_id,
        &protocol::CollectionRefreshRequest {
            expected_result_version: page.result_version,
            request_id: "change-after-playing".into(),
        },
        false,
    )
    .await
    .unwrap();
    let after = playback_session_snapshot_v3(&state, zone).await.unwrap();
    assert_eq!(after.queue_source, accepted.queue_source);
    assert_eq!(after.current_item_id, accepted.current_item_id);
    assert_eq!(
        after.queue.iter().map(|i| i.item_id).collect::<Vec<_>>(),
        accepted.queue.iter().map(|i| i.item_id).collect::<Vec<_>>()
    );
    sqlx::query("UPDATE files SET deleted_at=?1")
        .bind(&now)
        .execute(state.pool())
        .await
        .unwrap();
    let unavailable = submit(&state, zone, command(&state, zone, action.clone()).await).await;
    assert_ne!(unavailable.status, PlaybackCommandStatusV3::Applied);
    let retained = playback_session_snapshot_v3(&state, zone).await.unwrap();
    assert_eq!(retained.current_item_id, accepted.current_item_id);
    assert_eq!(retained.queue_source, accepted.queue_source);
    sqlx::query("DELETE FROM collection_play_plans WHERE id=?1")
        .bind(&source.plan_id)
        .execute(state.pool())
        .await
        .unwrap();
    let expired = submit(&state, zone, command(&state, zone, action).await).await;
    assert_eq!(
        expired.error_code.as_deref(),
        Some("collection_result_expired")
    );
    let retained = playback_session_snapshot_v3(&state, zone).await.unwrap();
    assert_eq!(retained.queue_source, accepted.queue_source);
    assert_eq!(retained.current_item_id, accepted.current_item_id);
    cleanup(state, dir).await;
}

#[tokio::test]
async fn eof_advances_the_owning_output_once_and_keeps_duplicate_occurrences() {
    let (state, dir) = state().await;
    let zone = "renderer:mac:a";
    let initial = start(&state, zone).await;
    let other = start(&state, "renderer:mac:b").await;
    assert_eq!(initial.transport, PlaybackTransportState::Loading);
    let sequence = initial.command_sequence.unwrap();
    let eof = command(
        &state,
        zone,
        PlaybackSessionActionV3::Complete {
            command_sequence: sequence,
        },
    )
    .await;
    let ack = submit(&state, zone, eof.clone()).await;
    assert_eq!(ack.status, PlaybackCommandStatusV3::Applied);
    assert_eq!(
        ack.snapshot.as_ref().unwrap().current_item_id,
        Some(initial.queue[1].item_id)
    );
    assert_eq!(
        submit(&state, zone, eof).await.status,
        PlaybackCommandStatusV3::Duplicate
    );
    let stale = command(
        &state,
        zone,
        PlaybackSessionActionV3::Complete {
            command_sequence: sequence,
        },
    )
    .await;
    assert_eq!(
        submit(&state, zone, stale).await.status,
        PlaybackCommandStatusV3::Rejected
    );
    let after = playback_session_snapshot_v3(&state, zone).await.unwrap();
    assert_eq!(after.current_item_id, Some(initial.queue[1].item_id));
    assert_eq!(
        playback_session_snapshot_v3(&state, "renderer:mac:b")
            .await
            .unwrap()
            .current_item_id,
        other.current_item_id
    );
    cleanup(state, dir).await;
}

#[tokio::test]
async fn output_transfer_keeps_full_queue_policy_and_advances_at_eof() {
    for stop_source in [true, false] {
        let (state, dir) = state().await;
        let source_zone = "renderer:mac:a";
        let target_zone = "renderer:mac:b";
        let initial = start(&state, source_zone).await;
        let old_target = start(&state, target_zone).await;
        let source = protocol::CollectionQueueSource {
            collection_id: 3,
            result_version: "favorites-batch".into(),
            plan_id: "favorites-plan".into(),
            name: "我喜欢".into(),
        };
        core_db::replace_playback_queue_v3(
            state.pool(),
            source_zone,
            &initial.queue,
            Some(initial.queue[1].item_id),
            Some(&source),
        )
        .await
        .unwrap();
        let mode = PlaybackSessionModeV3 {
            repeat: PlaybackRepeatModeV3::All,
            shuffle: true,
            stop_after_current: false,
        };
        core_db::update_playback_session_mode_v3(state.pool(), source_zone, mode)
            .await
            .unwrap();
        let before = playback_session_snapshot_v3(&state, source_zone)
            .await
            .unwrap();
        let _ = transfer_zone(
            State(state.clone()),
            Path(source_zone.into()),
            Json(protocol::ZoneTransferRequest {
                target_zone_id: target_zone.into(),
                stop_source,
            }),
        )
        .await
        .unwrap();
        let transferred = playback_session_snapshot_v3(&state, target_zone)
            .await
            .unwrap();
        assert_eq!(transferred.queue, before.queue);
        assert_eq!(transferred.current_item_id, before.current_item_id);
        assert_eq!(transferred.queue_source, Some(source));
        assert_eq!(transferred.mode, mode);
        assert_eq!(transferred.shuffle_seed, before.shuffle_seed);
        assert!(transferred.epoch > old_target.epoch);
        assert_eq!(transferred.transport, PlaybackTransportState::Loading);
        let source_after = playback_session_snapshot_v3(&state, source_zone)
            .await
            .unwrap();
        assert_eq!(source_after.queue, before.queue);
        assert_eq!(
            source_after.transport == PlaybackTransportState::Stopped,
            stop_source
        );

        let QueueAdvanceV3::Select(expected) = next_item(&transferred, true) else {
            panic!("queue should continue")
        };
        let eof = command(
            &state,
            target_zone,
            PlaybackSessionActionV3::Complete {
                command_sequence: transferred.command_sequence.unwrap(),
            },
        )
        .await;
        let ack = submit(&state, target_zone, eof.clone()).await;
        assert_eq!(ack.status, PlaybackCommandStatusV3::Applied);
        assert_eq!(ack.snapshot.unwrap().current_item_id, Some(expected));
        assert_eq!(
            submit(&state, target_zone, eof).await.status,
            PlaybackCommandStatusV3::Duplicate
        );
        let source_final = playback_session_snapshot_v3(&state, source_zone)
            .await
            .unwrap();
        assert_eq!(source_final.current_item_id, before.current_item_id);
        cleanup(state, dir).await;
    }
}

#[tokio::test]
async fn failed_output_transfer_preserves_both_queues() {
    let (state, dir) = state().await;
    let before = start(&state, "renderer:mac:a").await;
    let result = transfer_zone(
        State(state.clone()),
        Path("renderer:mac:a".into()),
        Json(protocol::ZoneTransferRequest {
            target_zone_id: "renderer:missing:a".into(),
            stop_source: true,
        }),
    )
    .await;
    assert!(result.is_err());
    let after = playback_session_snapshot_v3(&state, "renderer:mac:a")
        .await
        .unwrap();
    assert_eq!(after.queue, before.queue);
    assert_eq!(after.transport, before.transport);
    cleanup(state, dir).await;
}

#[tokio::test]
async fn stopped_report_never_means_eof_and_current_removal_updates_audio() {
    let (state, dir) = state().await;
    let zone = "renderer:mac:a";
    let initial = start(&state, zone).await;
    let _ = report_renderer_state(
        State(state.clone()),
        Path("mac".into()),
        Json(RendererStateReport {
            output_id: zone.into(),
            state: PlaybackTransportState::Stopped,
            track_id: None,
            track_title: None,
            position_ms: 0,
            command_sequence: initial.command_sequence,
            origin_client_id: None,
            intent_id: None,
        }),
    )
    .await
    .unwrap();
    assert_eq!(
        playback_session_snapshot_v3(&state, zone)
            .await
            .unwrap()
            .current_item_id,
        initial.current_item_id
    );
    let initial = start(&state, zone).await;
    let remove = command(
        &state,
        zone,
        PlaybackSessionActionV3::RemoveQueueItem {
            item_id: initial.current_item_id.unwrap(),
        },
    )
    .await;
    let ack = submit(&state, zone, remove).await;
    let after = ack.snapshot.unwrap();
    assert_eq!(after.current_item_id, Some(initial.queue[1].item_id));
    assert!(after.command_sequence > initial.command_sequence);
    assert_eq!(after.shuffle_seed, initial.shuffle_seed);
    cleanup(state, dir).await;
}
