use super::*;

#[tokio::test]
async fn playback_command_receipt_preserves_first_result() {
    let (pool, path) = test_pool().await;
    record_playback_command_receipt(
        &pool,
        "client-a",
        "intent-1",
        "renderer:client-a:default",
        "next",
        r#"{"track_id":2}"#,
    )
    .await
    .expect("record receipt");
    record_playback_command_receipt(
        &pool,
        "client-a",
        "intent-1",
        "renderer:client-a:default",
        "next",
        r#"{"track_id":3}"#,
    )
    .await
    .expect("duplicate receipt");

    let receipt = playback_command_receipt(&pool, "client-a", "intent-1")
        .await
        .expect("load receipt")
        .expect("stored receipt");
    assert_eq!(receipt.zone_id, "renderer:client-a:default");
    assert_eq!(receipt.action, "next");
    assert_eq!(receipt.response_json, r#"{"track_id":2}"#);
    close_test_pool(pool, path).await;
}
