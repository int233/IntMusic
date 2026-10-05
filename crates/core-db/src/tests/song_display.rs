use super::*;

#[tokio::test]
async fn display_choice_follows_edition_copies_but_not_other_albums() {
    let (pool, path) = test_pool().await;
    let lover = ingest_test_track(&pool, "lover.flac", "Lover", "Cruel Summer").await;
    let tour = ingest_test_track(&pool, "tour.flac", "The Eras Tour", "Cruel Summer").await;
    reconcile_catalog_identity(&pool).await.unwrap();
    let before = track_source_candidates(&pool, lover).await.unwrap();
    set_track_display_mode(&pool, lover, "independent")
        .await
        .unwrap();
    // A later copy inherits the existing preference without copying settings at ingest.
    let copy = ingest_test_track(&pool, "lover-copy.flac", "Lover", "Cruel Summer").await;
    reconcile_catalog_identity(&pool).await.unwrap();
    let a = track_detail(&pool, lover).await.unwrap().track;
    let b = track_detail(&pool, tour).await.unwrap().track;
    let c = track_detail(&pool, copy).await.unwrap().track;
    assert_eq!(a.display_group_key, b.display_group_key);
    assert_eq!(a.display_mode, "independent");
    assert_eq!(b.display_mode, "inherit");
    assert_eq!(c.display_mode, "independent");
    assert_ne!(a.release_identity_id, b.release_identity_id);
    assert_eq!(a.release_identity_id, c.release_identity_id);
    assert!(a.is_available);
    set_track_display_mode(&pool, copy, "merged").await.unwrap();
    assert_eq!(
        track_detail(&pool, lover).await.unwrap().track.display_mode,
        "merged"
    );
    assert!(set_track_display_mode(&pool, lover, "bogus").await.is_err());
    assert_eq!(
        track_source_candidates(&pool, lover).await.unwrap()[0].file_id,
        before[0].file_id
    );
    assert_eq!(
        search_tracks(&pool, "合并展示", 100).await.unwrap().len(),
        1
    );
    migrate(&pool).await.unwrap();
    let mut def = empty_collection(protocol::EntityType::Track);
    def.name = "Merged songs".into();
    def.automatic = Some(protocol::CollectionPredicate::Field {
        field: "display_mode".into(),
        op: "eq".into(),
        value: serde_json::json!("merged"),
    });
    let preview = preview_collection(&pool, &def, false).await.unwrap();
    assert_eq!(preview["items"][0]["data"]["id"], lover);
    assert_eq!(preview["result_total"], 1);
    // Rescan never overwrites a user display choice.
    ingest_test_track(&pool, "lover.flac", "Lover", "Cruel Summer").await;
    assert_eq!(
        track_detail(&pool, lover).await.unwrap().track.display_mode,
        "merged"
    );
    close_test_pool(pool, path).await;
}

fn mapping(
    source: &str,
    targets: &[&str],
    fields: &[protocol::TagMappingField],
) -> protocol::TagMappingRule {
    protocol::TagMappingRule {
        source: source.into(),
        targets: targets.iter().map(|s| s.to_string()).collect(),
        fields: fields.to_vec(),
    }
}

fn tag_settings(rules: Vec<protocol::TagMappingRule>) -> TagSettings {
    TagSettings {
        artist_separators: vec![";".into()],
        genre_separators: vec!["|".into()],
        tag_mappings: rules,
    }
}

#[test]
fn only_user_rules_map_exact_tags_in_selected_fields_without_chaining() {
    use protocol::TagMappingField::*;
    let rules = vec![
        mapping("国语流行", &["国语", "流行"], &[Genres]),
        mapping("流行", &["Pop"], &[Genres]),
        mapping(
            "国语流行",
            &["歌手甲", "歌手乙"],
            &[TrackArtists, Composers],
        ),
    ];
    let values = vec!["国语流行|粤语流行|另类国语流行|R&B/Soul".into()];
    assert_eq!(
        map_tag_values(Genres, &values, &["|".into()], &rules),
        ["国语", "流行", "粤语流行", "另类国语流行", "R&B/Soul"]
    );
    assert_eq!(
        map_tag_values(Genres, &["国语流行".into()], &[], &[]),
        ["国语流行"]
    );
    assert_eq!(
        map_tag_values(TrackArtists, &["国语流行".into()], &[], &rules),
        ["歌手甲", "歌手乙"]
    );
    assert_eq!(
        map_tag_values(Lyricists, &["国语流行".into()], &[], &rules),
        ["国语流行"]
    );
    let literal = vec![mapping("A", &["R&B/Soul;Pop", "B"], &[Genres])];
    assert_eq!(
        map_tag_values(Genres, &["A".into()], &[";".into(), "/".into()], &literal),
        ["R&B/Soul;Pop", "B"]
    );
}

#[test]
fn mapping_validation_enforces_output_bounds_fields_and_conflicts() {
    use protocol::TagMappingField::*;
    for count in 1..=5 {
        let targets: Vec<_> = (0..count).map(|i| format!("tag {i}")).collect();
        assert!(validate_tag_mappings(vec![protocol::TagMappingRule {
            source: "input".into(),
            targets,
            fields: vec![Genres]
        }])
        .is_ok());
    }
    for rule in [
        mapping("", &["x"], &[Genres]),
        mapping("x", &[], &[Genres]),
        mapping("x", &["a", "b", "c", "d", "e", "f"], &[Genres]),
        mapping("x", &[" "], &[Genres]),
        mapping("x", &["A", "a"], &[Genres]),
        mapping("x", &["a"], &[]),
    ] {
        assert!(validate_tag_mappings(vec![rule]).is_err());
    }
    assert!(validate_tag_mappings(vec![
        mapping("x", &["a"], &[Genres]),
        mapping("x", &["b"], &[Genres])
    ])
    .is_err());
    assert!(validate_tag_mappings(vec![
        mapping("x", &["a"], &[Genres]),
        mapping("x", &["b"], &[Composers])
    ])
    .is_ok());
}

#[tokio::test]
async fn mappings_recompute_from_originals_are_searchable_and_can_be_removed() {
    use protocol::TagMappingField::*;
    let (pool, path) = test_pool().await;
    let track = ingest_test_track(&pool, "genre.flac", "Album", "Song").await;
    let file_id = track_detail(&pool, track).await.unwrap().track.file_id;
    let mut raw = load_track_metadata_source(&pool, file_id)
        .await
        .unwrap()
        .unwrap();
    raw.genres = vec!["国语流行|粤语流行".into(), "R&B/Soul".into()];
    save_track_metadata_source(&pool, file_id, &raw)
        .await
        .unwrap();
    let rules = vec![
        mapping("国语流行", &["国语", "流行"], &[Genres]),
        mapping("粤语流行", &["粤语", "流行"], &[Genres]),
    ];
    configure_tag_settings(&pool, &tag_settings(rules))
        .await
        .unwrap();
    assert_eq!(apply_existing_tag_mappings(&pool).await.unwrap(), 1);
    assert_eq!(apply_existing_tag_mappings(&pool).await.unwrap(), 0);
    let summary = track_detail(&pool, track).await.unwrap().track;
    assert_eq!(summary.genres.len(), 4);
    assert_eq!(
        search_tracks(&pool, "粤语", 100).await.unwrap()[0].id,
        track
    );
    assert_eq!(
        serde_json::to_value(
            load_track_metadata_source(&pool, file_id)
                .await
                .unwrap()
                .unwrap()
        )
        .unwrap(),
        serde_json::to_value(&raw).unwrap()
    );
    // Changing a rule does not depend on its source still appearing in output.
    configure_tag_settings(
        &pool,
        &tag_settings(vec![mapping("国语流行", &["自选标签"], &[Genres])]),
    )
    .await
    .unwrap();
    assert_eq!(apply_existing_tag_mappings(&pool).await.unwrap(), 1);
    assert!(track_detail(&pool, track)
        .await
        .unwrap()
        .track
        .genres
        .contains(&"自选标签".into()));
    configure_tag_settings(&pool, &tag_settings(vec![]))
        .await
        .unwrap();
    assert_eq!(apply_existing_tag_mappings(&pool).await.unwrap(), 1);
    assert_eq!(apply_existing_tag_mappings(&pool).await.unwrap(), 0);
    let genres = track_detail(&pool, track).await.unwrap().track.genres;
    assert!(genres.contains(&"国语流行".into()) && genres.contains(&"粤语流行".into()));
    // Manual edits remain the input instead of being overwritten by file tags.
    let update = TrackMetadataUpdate {
        fields: vec![protocol::TrackMetadataFieldUpdate {
            key: "genres".into(),
            value: serde_json::json!(["手工标签"]),
        }],
        ..Default::default()
    };
    update_track_metadata(&pool, track, &update, None)
        .await
        .unwrap();
    configure_tag_settings(
        &pool,
        &tag_settings(vec![mapping(
            "手工标签",
            &["一", "二", "三", "四", "五"],
            &[Genres],
        )]),
    )
    .await
    .unwrap();
    apply_existing_tag_mappings(&pool).await.unwrap();
    assert_eq!(
        track_detail(&pool, track).await.unwrap().track.genres.len(),
        5
    );
    assert_eq!(apply_existing_tag_mappings(&pool).await.unwrap(), 0);
    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn artist_album_artist_and_credit_rules_apply_without_changing_other_fields() {
    use protocol::TagMappingField::*;
    let (pool, path) = test_pool().await;
    let track = ingest_test_track(&pool, "credits.flac", "Album", "Song").await;
    let file_id = track_detail(&pool, track).await.unwrap().track.file_id;
    let mut raw = load_track_metadata_source(&pool, file_id)
        .await
        .unwrap()
        .unwrap();
    raw.track_artists = vec!["共同标签".into()];
    raw.album_artists = vec!["共同标签".into()];
    raw.composers = vec!["共同标签".into()];
    raw.lyricists = vec!["共同标签".into()];
    raw.genres = vec!["共同标签".into()];
    save_track_metadata_source(&pool, file_id, &raw)
        .await
        .unwrap();
    configure_tag_settings(
        &pool,
        &tag_settings(vec![mapping(
            "共同标签",
            &["甲", "乙"],
            &[TrackArtists, AlbumArtists, Composers, Lyricists],
        )]),
    )
    .await
    .unwrap();
    assert_eq!(apply_existing_tag_mappings(&pool).await.unwrap(), 1);
    let result = current_track_ingest(&pool, track).await.unwrap();
    for values in [
        &result.track_artists,
        &result.album_artists,
        &result.composers,
        &result.lyricists,
    ] {
        assert_eq!(values, &["甲", "乙"]);
    }
    assert_eq!(result.genres, ["共同标签"]);
    assert_eq!(result.title, "Song");
    assert_eq!(result.album.as_deref(), Some("Album"));
    assert_eq!(apply_existing_tag_mappings(&pool).await.unwrap(), 0);
    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn new_ingest_and_rescan_apply_rules_once_and_keep_original_metadata() {
    use protocol::TagMappingField::*;
    let (pool, path) = test_pool().await;
    configure_tag_settings(
        &pool,
        &tag_settings(vec![
            mapping("Artist", &["甲;乙", "丙"], &[TrackArtists]),
            mapping("丙", &["不应触发"], &[TrackArtists]),
        ]),
    )
    .await
    .unwrap();
    let id = ingest_test_track(&pool, "new-mapped.flac", "Album", "Song").await;
    let current = current_track_ingest(&pool, id).await.unwrap();
    assert_eq!(current.track_artists, ["甲;乙", "丙"]);
    let file_id = track_detail(&pool, id).await.unwrap().track.file_id;
    assert_eq!(
        load_track_metadata_source(&pool, file_id)
            .await
            .unwrap()
            .unwrap()
            .track_artists,
        ["Artist"]
    );
    ingest_test_track(&pool, "new-mapped.flac", "Album", "Song").await;
    assert_eq!(
        current_track_ingest(&pool, id).await.unwrap().track_artists,
        ["甲;乙", "丙"]
    );
    assert_eq!(apply_existing_tag_mappings(&pool).await.unwrap(), 0);
    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn repeated_application_respects_shared_artist_and_album_identity() {
    let (pool, path) = test_pool().await;
    for (filename, names, album) in [
        ("case-a.flac", vec!["Alpha", "Beta"], Some("Shared")),
        ("case-b.flac", vec!["BETA", "ALPHA"], Some("Shared")),
        ("no-album.flac", vec!["Alpha"], None),
    ] {
        let id = ingest_test_track(&pool, filename, "Shared", filename).await;
        let file_id = track_detail(&pool, id).await.unwrap().track.file_id;
        let mut source = load_track_metadata_source(&pool, file_id)
            .await
            .unwrap()
            .unwrap();
        source.album = album.map(str::to_string);
        source.track_artists = names.iter().map(|s| s.to_string()).collect();
        source.album_artists = source.track_artists.clone();
        source.composers = vec!["ALPHA".into()];
        source.genres = vec!["未映射流派".into()];
        let file = file_ingest_by_id(&pool, file_id).await.unwrap();
        upsert_scanned_file(&pool, &file, Some(&source))
            .await
            .unwrap();
    }
    configure_tag_settings(&pool, &tag_settings(vec![]))
        .await
        .unwrap();
    assert_eq!(apply_existing_tag_mappings(&pool).await.unwrap(), 0);
    close_test_pool(pool, path).await;
}
