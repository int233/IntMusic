use protocol::{PlaybackQueueItemV3, PlaybackRepeatModeV3, PlaybackSessionModeV3};

use super::*;

#[tokio::test]
async fn v3_session_and_queue_identities_are_durable() {
    let (pool, path) = test_pool().await;
    let session = ensure_playback_session_v3(&pool, "local", "core", 7)
        .await
        .expect("create session");
    assert_eq!(session.epoch, 1);
    assert_eq!(session.revision, 0);

    let first_id = Uuid::now_v7();
    let second_id = Uuid::now_v7();
    let now = Utc::now();
    let items = vec![
        PlaybackQueueItemV3 {
            item_id: first_id,
            track_id: 1,
            added_by_device_id: "client-a".to_string(),
            added_at: now,
        },
        PlaybackQueueItemV3 {
            item_id: second_id,
            track_id: 2,
            added_by_device_id: "client-a".to_string(),
            added_at: now,
        },
    ];
    replace_playback_queue_v3(&pool, "local", &items, Some(second_id))
        .await
        .expect("replace queue");
    let queue = playback_queue_state_v3(&pool, "local")
        .await
        .expect("load queue");
    assert_eq!(queue.items, items);
    assert_eq!(queue.current_item_id, Some(second_id));

    update_playback_session_mode_v3(
        &pool,
        "local",
        PlaybackSessionModeV3 {
            repeat: PlaybackRepeatModeV3::All,
            shuffle: true,
            stop_after_current: false,
        },
    )
    .await
    .expect("update mode");
    let command_id = Uuid::now_v7();
    let advanced = advance_playback_session_v3(&pool, "local", command_id, 9)
        .await
        .expect("advance session");
    assert_eq!(advanced.revision, 1);
    assert_eq!(advanced.event_cursor, 9);
    assert_eq!(advanced.last_command_id, Some(command_id));
    assert!(advanced.mode.shuffle);
    assert_eq!(advanced.mode.repeat, PlaybackRepeatModeV3::All);

    let transferred = ensure_playback_session_v3(&pool, "local", "client-b", 10)
        .await
        .expect("transfer owner");
    assert_eq!(transferred.session_id, session.session_id);
    assert_eq!(transferred.epoch, 2);
    assert_eq!(transferred.revision, 2);
    assert_eq!(transferred.owner_device_id, "client-b");
    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn legacy_queue_rows_receive_stable_v3_ids() {
    let (pool, path) = test_pool().await;
    replace_playback_queue(
        &pool,
        "local",
        protocol::ReplacePlaybackQueue {
            track_ids: vec![1, 2],
            start_index: Some(0),
            mode: None,
        },
    )
    .await
    .expect("create legacy queue");
    let first = playback_queue_state_v3(&pool, "local")
        .await
        .expect("first v3 read");
    let second = playback_queue_state_v3(&pool, "local")
        .await
        .expect("second v3 read");
    assert_eq!(first.items, second.items);
    assert_eq!(first.items.len(), 2);
    close_test_pool(pool, path).await;
}
