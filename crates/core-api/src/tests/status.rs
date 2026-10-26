use super::*;

#[tokio::test]
async fn readiness_and_status_do_not_wait_for_an_exhausted_database_pool() {
    let directory = std::env::temp_dir().join(format!("intmusic-health-{}", Uuid::now_v7()));
    let paths =
        CorePaths::discover(Some(directory.join("config.toml")), Some(directory.clone())).unwrap();
    let pool = sqlx::sqlite::SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .unwrap();
    let occupied = pool.acquire().await.unwrap();
    let transcoder = Transcoder::discover(TranscoderSettings {
        enabled: false,
        ffmpeg_path: None,
        ffprobe_path: None,
        cache_dir: directory.join("cache"),
        max_cache_bytes: 0,
        max_concurrent_jobs: 1,
    })
    .await;
    let state = AppState::new(
        CoreConfig::default(),
        paths,
        pool.clone(),
        (Uuid::now_v7(), "epoch".into()),
        "127.0.0.1:0".parse().unwrap(),
        None,
        transcoder,
    );
    state.inner.library_counts.write().unwrap().tracks = 6061;
    let response = tokio::time::timeout(Duration::from_millis(200), status(State(state.clone())))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(response.0.counts.tracks, 6061);
    let response = tokio::time::timeout(Duration::from_millis(200), health(State(state.clone())))
        .await
        .unwrap();
    assert_eq!(response.0["ready"], true);
    assert_eq!(response.0["name"], "IntMusic Local Music Core");
    drop(occupied);
    drop(state);
    pool.close().await;
}
