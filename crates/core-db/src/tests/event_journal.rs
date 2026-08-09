use super::*;

#[tokio::test]
async fn event_journal_replays_in_cursor_order() {
    let (pool, path) = test_pool().await;
    let mut first = EventEnvelope::new("library.changed", serde_json::json!({ "revision": 2 }));
    first.cursor = Some(1);
    let mut second = EventEnvelope::new(
        "playback.queue_changed",
        serde_json::json!({ "revision": 3 }),
    );
    second.cursor = Some(2);

    record_event(&pool, &first)
        .await
        .expect("record first event");
    record_event(&pool, &second)
        .await
        .expect("record second event");
    record_event(&pool, &second)
        .await
        .expect("duplicate event is idempotent");

    assert_eq!(event_journal_cursor(&pool).await.expect("cursor"), 2);
    let first_page = replay_events(&pool, 0, 1).await.expect("first page");
    assert_eq!(first_page.events.len(), 1);
    assert_eq!(first_page.events[0].id, first.id);
    assert_eq!(first_page.scanned_cursor, 1);
    assert!(first_page.has_more);
    assert!(!first_page.requires_snapshot);

    let second_page = replay_events(&pool, first_page.scanned_cursor, 10)
        .await
        .expect("second page");
    assert_eq!(second_page.events.len(), 1);
    assert_eq!(second_page.events[0].id, second.id);
    assert_eq!(second_page.scanned_cursor, 2);
    assert!(!second_page.has_more);
    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn event_journal_reports_retention_gap() {
    let (pool, path) = test_pool().await;
    let mut event = EventEnvelope::new("core.settings_changed", serde_json::json!({}));
    event.cursor = Some(10);
    record_event(&pool, &event).await.expect("record event");

    let page = replay_events(&pool, 2, 10).await.expect("replay page");
    assert!(page.requires_snapshot);
    assert_eq!(page.scanned_cursor, 10);
    close_test_pool(pool, path).await;
}
