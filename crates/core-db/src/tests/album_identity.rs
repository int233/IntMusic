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
