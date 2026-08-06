use super::*;

#[tokio::test]
async fn source_scoped_album_rows_are_exposed_as_one_catalog_album() {
    let (pool, path) = test_pool().await;
    let first = ingest_test_track(&pool, "first.flac", "Shared album", "First song").await;
    let second = ingest_test_track(&pool, "second.flac", "Shared album", "Second song").await;
    let canonical_album_id: i64 = sqlx::query_scalar("SELECT album_id FROM tracks WHERE id = ?1")
        .bind(first)
        .fetch_one(&pool)
        .await
        .expect("canonical album");
    let now = Utc::now().to_rfc3339();
    let duplicate_album_id: i64 = sqlx::query_scalar(
        r#"
        INSERT INTO albums (
            title, normalized_title, album_key, album_artist_display,
            date, year, total_discs, created_at, updated_at
        ) VALUES (
            'Shared album', 'shared album', 'legacy-source-album',
            'Beta; Alpha', '2020', 2020, 1, ?1, ?1
        )
        RETURNING id
        "#,
    )
    .bind(&now)
    .fetch_one(&pool)
    .await
    .expect("duplicate source album");

    let alpha = upsert_artist(&pool, "Alpha").await.expect("alpha artist");
    let beta = upsert_artist(&pool, "Beta").await.expect("beta artist");
    sqlx::query("DELETE FROM album_artists WHERE album_id = ?1 OR album_id = ?2")
        .bind(canonical_album_id)
        .bind(duplicate_album_id)
        .execute(&pool)
        .await
        .expect("replace album artists");
    for (album_id, artists) in [
        (canonical_album_id, [alpha, beta]),
        (duplicate_album_id, [beta, alpha]),
    ] {
        for (position, artist_id) in artists.into_iter().enumerate() {
            sqlx::query(
                "INSERT INTO album_artists (album_id, artist_id, position) VALUES (?1, ?2, ?3)",
            )
            .bind(album_id)
            .bind(artist_id)
            .bind(position as i64)
            .execute(&pool)
            .await
            .expect("insert album artist");
        }
    }
    sqlx::query("UPDATE albums SET album_artist_display = 'Alpha; Beta' WHERE id = ?1")
        .bind(canonical_album_id)
        .execute(&pool)
        .await
        .expect("canonical display artists");
    sqlx::query("UPDATE tracks SET album_id = ?1 WHERE id = ?2")
        .bind(duplicate_album_id)
        .bind(second)
        .execute(&pool)
        .await
        .expect("move second source track to duplicate album");

    let albums = list_albums(&pool, 100, 0).await.expect("catalog albums");
    let shared = albums
        .iter()
        .filter(|album| album.title == "Shared album")
        .collect::<Vec<_>>();
    assert_eq!(shared.len(), 1);
    assert_eq!(shared[0].id, canonical_album_id);
    assert_eq!(shared[0].track_count, 2);

    let search = search_albums(&pool, "Shared album", 20)
        .await
        .expect("search catalog albums");
    assert_eq!(search.len(), 1);
    assert_eq!(search[0].id, canonical_album_id);

    let detail = album_detail(&pool, duplicate_album_id)
        .await
        .expect("detail through duplicate album ID");
    assert_eq!(detail.album.id, canonical_album_id);
    assert_eq!(detail.tracks.len(), 2);
    assert_eq!(library_counts(&pool).await.expect("counts").albums, 1);

    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn album_editor_keeps_album_metadata_separate_from_track_exceptions() {
    let (pool, path) = test_pool().await;
    let first = ingest_test_track(&pool, "return-1.flac", "Return", "First song").await;
    let second = ingest_test_track(&pool, "return-2.flac", "Return", "Second song").await;
    let album_id: i64 = sqlx::query_scalar("SELECT album_id FROM tracks WHERE id = ?1")
        .bind(first)
        .fetch_one(&pool)
        .await
        .expect("album ID");
    let artist_id = upsert_artist(&pool, "Artist").await.expect("artist");

    let snapshot = update_album_metadata(
        &pool,
        album_id,
        &UpdateAlbumMetadata {
            expected_revision: Some(0),
            profile: AlbumMetadataProfile {
                title: Some("归来吧".to_string()),
                date: Some("1992-10-01".to_string()),
                year: Some(1992),
                total_discs: Some(2),
                labels: vec!["Example Records".to_string()],
                genres: vec!["Pop".to_string(), "Mandopop".to_string()],
                ..Default::default()
            },
            credits: vec![
                AlbumCredit {
                    artist_id: Some(artist_id),
                    artist_name: Some("Artist".to_string()),
                    display_name: "Artist".to_string(),
                    role: "album_artist".to_string(),
                    ..Default::default()
                },
                AlbumCredit {
                    display_name: "Producer A".to_string(),
                    role: "producer".to_string(),
                    ..Default::default()
                },
            ],
            propagate: Some(AlbumTrackPropagation {
                track_ids: vec![first],
                fields: vec![
                    "date".to_string(),
                    "year".to_string(),
                    "disc_total".to_string(),
                    "genres".to_string(),
                ],
            }),
        },
    )
    .await
    .expect("update album metadata");

    assert_eq!(snapshot.revision, 1);
    assert_eq!(snapshot.detail.album.title, "归来吧");
    assert_eq!(snapshot.detail.profile.year, Some(1992));
    assert_eq!(snapshot.detail.profile.total_discs, Some(2));
    assert_eq!(snapshot.detail.profile.labels, ["Example Records"]);
    assert_eq!(snapshot.detail.credits.len(), 2);
    assert_eq!(snapshot.detail.credits[0].artist_id, Some(artist_id));

    let first_values: (Option<String>, Option<i64>, Option<i64>) =
        sqlx::query_as("SELECT date, year, disc_total FROM tracks WHERE id = ?1")
            .bind(first)
            .fetch_one(&pool)
            .await
            .expect("first track values");
    let second_values: (Option<String>, Option<i64>, Option<i64>) =
        sqlx::query_as("SELECT date, year, disc_total FROM tracks WHERE id = ?1")
            .bind(second)
            .fetch_one(&pool)
            .await
            .expect("second track values");
    assert_eq!(
        first_values,
        (Some("1992-10-01".to_string()), Some(1992), Some(2))
    );
    assert_eq!(second_values, (None, Some(2020), None));

    let propagated_genres: Vec<String> = sqlx::query_scalar(
        "SELECT genre.name FROM track_genres JOIN genres genre ON genre.id = track_genres.genre_id WHERE track_genres.track_id = ?1 ORDER BY genre.name",
    )
    .bind(first)
    .fetch_all(&pool)
    .await
    .expect("propagated genres");
    assert_eq!(propagated_genres, ["Mandopop", "Pop"]);
    let untouched_genre_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM track_genres WHERE track_id = ?1")
            .bind(second)
            .fetch_one(&pool)
            .await
            .expect("untouched genres");
    assert_eq!(untouched_genre_count, 0);
    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn album_migration_folds_a_split_album_without_removing_tracks_or_files() {
    let (pool, path) = test_pool().await;
    let target_track = ingest_test_track(&pool, "return-tagged.flac", "归来吧", "Known year").await;
    let source_track =
        ingest_test_track(&pool, "return-undated.flac", "归来吧", "Missing year").await;
    let target_album_id: i64 = sqlx::query_scalar("SELECT album_id FROM tracks WHERE id = ?1")
        .bind(target_track)
        .fetch_one(&pool)
        .await
        .expect("target album");
    let now = Utc::now().to_rfc3339();
    let source_album_id: i64 = sqlx::query_scalar(
        r#"
        INSERT INTO albums (
            title, normalized_title, album_key, album_artist_display,
            created_at, updated_at
        ) VALUES ('归来吧', '归来吧', 'return-without-year', 'Artist', ?1, ?1)
        RETURNING id
        "#,
    )
    .bind(&now)
    .fetch_one(&pool)
    .await
    .expect("split album");
    sqlx::query("UPDATE tracks SET album_id = ?1, year = NULL WHERE id = ?2")
        .bind(source_album_id)
        .bind(source_track)
        .execute(&pool)
        .await
        .expect("move undated track");
    assert_ne!(target_album_id, source_album_id);
    let files_before: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM files")
        .fetch_one(&pool)
        .await
        .expect("files before");

    let result = migrate_album(&pool, source_album_id, target_album_id)
        .await
        .expect("migrate album");
    assert_eq!(result.target_album_id, target_album_id);
    assert_eq!(result.moved_track_count, 1);
    assert_eq!(result.detail.tracks.len(), 2);
    assert_eq!(
        album_detail(&pool, source_album_id)
            .await
            .expect("source redirects to target")
            .album
            .id,
        target_album_id
    );
    let visible = list_albums(&pool, 100, 0).await.expect("visible albums");
    assert_eq!(
        visible
            .iter()
            .filter(|album| album.title == "归来吧")
            .count(),
        1
    );
    let files_after: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM files")
        .fetch_one(&pool)
        .await
        .expect("files after");
    assert_eq!(files_after, files_before);
    close_test_pool(pool, path).await;
}
