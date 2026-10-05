use super::*;
use protocol::*;
use serde_json::json;

fn field(field: &str, op: &str, value: Value) -> CollectionPredicate {
    CollectionPredicate::Field {
        field: field.into(),
        op: op.into(),
        value,
    }
}
fn all(conditions: Vec<CollectionPredicate>) -> CollectionPredicate {
    CollectionPredicate::All { conditions }
}
fn code(e: anyhow::Error) -> &'static str {
    e.downcast::<CollectionError>().unwrap().code
}
async fn fixture() -> (DbPool, PathBuf) {
    let (pool, path) = test_pool().await;
    let now = Utc::now().to_rfc3339();
    for (id, title) in [(1, "Lover"), (2, "The Eras Tour")] {
        sqlx::query("INSERT INTO albums(id,title,normalized_title,album_key,year,created_at,updated_at) VALUES(?1,?2,?2,?2,2019,?3,?3)").bind(id).bind(title).bind(&now).execute(&pool).await.unwrap();
    }
    for (id, name) in [(1, "Taylor Swift"), (2, "Other artist"), (3, "Composer")] {
        sqlx::query("INSERT INTO artists(id,name,normalized_name,created_at,updated_at) VALUES(?1,?2,?2,?3,?3)").bind(id).bind(name).bind(&now).execute(&pool).await.unwrap();
    }
    sqlx::query("UPDATE tracks SET album_id=CASE WHEN id=3 THEN 2 ELSE 1 END,track_number=id,title=CASE WHEN id IN (1,3) THEN 'Cruel Summer' ELSE 'Other song' END").execute(&pool).await.unwrap();
    sqlx::query("INSERT INTO track_artists(track_id,artist_id,role,position) VALUES(1,1,'primary',0),(2,1,'primary',0),(3,2,'primary',0),(1,3,'composer',0)").execute(&pool).await.unwrap();
    sqlx::query("INSERT INTO album_artists(album_id,artist_id,position) VALUES(1,1,0),(2,2,0)")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO genres(id,name,normalized_name) VALUES(1,'国语','国语'),(2,'粤语','粤语'),(3,'流行','流行')").execute(&pool).await.unwrap();
    sqlx::query("INSERT INTO track_genres(track_id,genre_id) VALUES(1,1),(1,3),(2,2),(2,3),(3,2)")
        .execute(&pool)
        .await
        .unwrap();
    set_track_favorite(
        &pool,
        1,
        TrackFavoriteUpdate {
            is_favorite: true,
            user_rating: None,
        },
    )
    .await
    .unwrap();
    set_track_favorite(
        &pool,
        3,
        TrackFavoriteUpdate {
            is_favorite: true,
            user_rating: None,
        },
    )
    .await
    .unwrap();
    migrate(&pool).await.unwrap();
    (pool, path)
}
async fn save(
    pool: &DbPool,
    kind: EntityType,
    automatic: Option<CollectionPredicate>,
) -> CollectionPage {
    let mut def = empty_collection(kind);
    def.name = "Test collection".into();
    def.automatic = automatic;
    save_collection(
        pool,
        None,
        &CollectionWrite {
            expected_revision: None,
            definition: def,
        },
        false,
    )
    .await
    .unwrap()
}
async fn release(pool: &DbPool, track: i64) -> i64 {
    sqlx::query_scalar("SELECT COALESCE(release_identity_id,release_track_id) FROM track_catalog_links WHERE track_id=?1").bind(track).fetch_one(pool).await.unwrap()
}

#[tokio::test]
async fn manual_is_empty_until_explicit_members_and_exclusions_override_rules() {
    let (pool, path) = fixture().await;
    let mut p = save(&pool, EntityType::Track, None).await;
    assert_eq!(p.result_total, 0);
    let first = release(&pool, 1).await;
    let second = release(&pool, 2).await;
    p.definition.included = vec![second];
    p.definition.excluded = vec![first];
    p.definition.automatic = Some(all(vec![]));
    let result = save_collection(
        &pool,
        Some(p.collection.id),
        &CollectionWrite {
            expected_revision: Some(p.collection.revision),
            definition: p.definition,
        },
        false,
    )
    .await
    .unwrap();
    assert_eq!(result.result_total, 2);
    assert_eq!(result.items[0].entity_id, second);
    assert_eq!(result.items[0].reason, "specified");
    assert!(result.items.iter().all(|i| i.entity_id != first));
    close_test_pool(pool, path).await;
}
#[tokio::test]
async fn related_conditions_bind_to_the_same_track_and_roles_are_explicit() {
    let (pool, path) = fixture().await;
    let predicate = CollectionPredicate::Tracks {
        quantifier: TrackQuantifier::Any,
        value: 1,
        role: ArtistTrackRole::Performer,
        condition: Box::new(all(vec![
            field("genres", "eq", json!("粤语")),
            field("favorite", "eq", json!(true)),
        ])),
    };
    let albums = save(&pool, EntityType::Album, Some(predicate)).await;
    assert_eq!(albums.result_total, 1);
    assert_eq!(albums.items[0].entity_id, 2);
    let composer = save(
        &pool,
        EntityType::Artist,
        Some(CollectionPredicate::Tracks {
            quantifier: TrackQuantifier::Any,
            value: 1,
            role: ArtistTrackRole::Composer,
            condition: Box::new(all(vec![])),
        }),
    )
    .await;
    assert_eq!(composer.result_total, 1);
    assert_eq!(composer.items[0].entity_id, 3);
    let performer = save(
        &pool,
        EntityType::Artist,
        Some(CollectionPredicate::Tracks {
            quantifier: TrackQuantifier::All,
            value: 1,
            role: ArtistTrackRole::Performer,
            condition: Box::new(all(vec![])),
        }),
    )
    .await;
    assert_eq!(performer.result_total, 2);
    assert!(performer.items.iter().all(|i| i.entity_id != 3));
    close_test_pool(pool, path).await;
}
#[tokio::test]
async fn genre_counts_use_logical_songs_and_own_genres_do_not_inherit_song_tags() {
    let (pool, path) = fixture().await;
    let genres = save(
        &pool,
        EntityType::Genre,
        Some(field("track_count", "gte", json!(2))),
    )
    .await;
    assert_eq!(genres.result_total, 2);
    let albums = save(
        &pool,
        EntityType::Album,
        Some(field("genres", "eq", json!("流行"))),
    )
    .await;
    assert_eq!(albums.result_total, 0);
    let g = collection_genre_detail(&pool, 2, false).await.unwrap();
    assert_eq!(g["tracks"].as_array().unwrap().len(), 2);
    close_test_pool(pool, path).await;
}
#[tokio::test]
async fn album_playback_scope_is_separate_and_snapshots_freeze_members() {
    let (pool, path) = fixture().await;
    let mut p = save(
        &pool,
        EntityType::Album,
        Some(field("name", "eq", json!("Lover"))),
    )
    .await;
    let old = p.result_version.clone().unwrap();
    let plan = collection_play_plan(
        &pool,
        p.collection.id,
        &CollectionPlayRequest {
            result_version: old.clone(),
            entity_ids: None,
        },
        false,
    )
    .await
    .unwrap();
    assert_eq!(plan.tracks.len(), 2);
    p.definition.playback.filter = Some(field("favorite", "eq", json!(true)));
    let updated = save_collection(
        &pool,
        Some(p.collection.id),
        &CollectionWrite {
            expected_revision: Some(p.collection.revision),
            definition: p.definition,
        },
        false,
    )
    .await
    .unwrap();
    let limited = collection_play_plan(
        &pool,
        p.collection.id,
        &CollectionPlayRequest {
            result_version: updated.result_version.unwrap(),
            entity_ids: None,
        },
        false,
    )
    .await
    .unwrap();
    assert_eq!(limited.tracks.len(), 1);
    assert_eq!(
        collection_play_plan(
            &pool,
            p.collection.id,
            &CollectionPlayRequest {
                result_version: old,
                entity_ids: None
            },
            false
        )
        .await
        .unwrap()
        .tracks
        .len(),
        2
    );
    let source = validate_collection_queue(
        &pool,
        &CollectionQueueSource {
            name: "forged".into(),
            ..plan.source.clone()
        },
        &[plan.tracks[0].id],
    )
    .await
    .unwrap();
    assert_eq!(source.name, "Test collection");
    assert_eq!(
        code(
            validate_collection_queue(&pool, &source, &[999999])
                .await
                .unwrap_err()
        ),
        "collection_invalid"
    );
    close_test_pool(pool, path).await;
}
#[tokio::test]
async fn defaults_are_unique_protected_and_layout_removal_does_not_recreate_cards() {
    let (pool, path) = fixture().await;
    initialize_collections(&pool).await.unwrap();
    let systems = list_collections(&pool).await.unwrap();
    assert_eq!(systems.len(), 2);
    assert!(systems.iter().all(|c| !c.can_delete && !c.can_edit));
    let id = systems[0].id;
    assert_eq!(
        code(delete_collection(&pool, id, 1).await.unwrap_err()),
        "collection_protected"
    );
    assert!(sqlx::query("DELETE FROM collections WHERE id=?1")
        .bind(id)
        .execute(&pool)
        .await
        .is_err());
    let layout = home_layout(&pool).await.unwrap();
    save_home_layout(
        &pool,
        &HomeLayoutUpdate {
            expected_revision: layout.revision,
            sections: vec![],
        },
    )
    .await
    .unwrap();
    initialize_collections(&pool).await.unwrap();
    assert!(home_layout(&pool).await.unwrap().sections.is_empty());
    assert_eq!(list_collections(&pool).await.unwrap().len(), 2);
    close_test_pool(pool, path).await;
}
#[tokio::test]
async fn management_is_checked_when_saving_and_invalid_rules_never_publish() {
    let (pool, path) = fixture().await;
    let daily = list_collections(&pool)
        .await
        .unwrap()
        .into_iter()
        .find(|c| c.system_key.as_deref() == Some("daily_mix"))
        .unwrap();
    let mut def = default_collection("daily_mix").unwrap();
    let write = CollectionWrite {
        expected_revision: Some(daily.revision),
        definition: def.clone(),
    };
    assert_eq!(
        code(
            save_collection(&pool, Some(daily.id), &write, false)
                .await
                .unwrap_err()
        ),
        "collection_management_disabled"
    );
    update_collection_settings(
        &pool,
        &CollectionSettingsUpdate {
            management_enabled: true,
            expected_revision: 1,
        },
    )
    .await
    .unwrap();
    let page = save_collection(&pool, Some(daily.id), &write, false)
        .await
        .unwrap();
    let mut disabled = page.definition.clone();
    disabled.automatic = None;
    assert_eq!(
        code(
            save_collection(
                &pool,
                Some(daily.id),
                &CollectionWrite {
                    expected_revision: Some(page.collection.revision),
                    definition: disabled
                },
                false
            )
            .await
            .unwrap_err()
        ),
        "collection_protected"
    );
    def.automatic = Some(field("unknown", "eq", json!(1)));
    let error = save_collection(
        &pool,
        Some(daily.id),
        &CollectionWrite {
            expected_revision: Some(page.collection.revision),
            definition: def,
        },
        false,
    )
    .await
    .unwrap_err();
    assert_eq!(code(error), "collection_invalid");
    assert_eq!(
        collection_page(&pool, daily.id, None, 0, 1)
            .await
            .unwrap()
            .result_version,
        page.result_version
    );
    close_test_pool(pool, path).await;
}
#[tokio::test]
async fn stale_edits_and_layout_writes_conflict_without_overwriting() {
    let (pool, path) = fixture().await;
    let p = save(&pool, EntityType::Track, None).await;
    let write = CollectionWrite {
        expected_revision: Some(p.collection.revision),
        definition: p.definition,
    };
    save_collection(&pool, Some(p.collection.id), &write, false)
        .await
        .unwrap();
    assert_eq!(
        code(
            save_collection(&pool, Some(p.collection.id), &write, false)
                .await
                .unwrap_err()
        ),
        "collection_conflict"
    );
    let layout = home_layout(&pool).await.unwrap();
    let update = HomeLayoutUpdate {
        expected_revision: layout.revision,
        sections: layout.sections,
    };
    save_home_layout(&pool, &update).await.unwrap();
    assert_eq!(
        code(save_home_layout(&pool, &update).await.unwrap_err()),
        "collection_conflict"
    );
    close_test_pool(pool, path).await;
}
#[tokio::test]
async fn refresh_is_idempotent_and_old_pages_remain_readable() {
    let (pool, path) = fixture().await;
    let p = save(&pool, EntityType::Track, Some(all(vec![]))).await;
    let req = CollectionRefreshRequest {
        expected_result_version: p.result_version.clone(),
        request_id: "refresh-once".into(),
    };
    let first = refresh_collection(&pool, p.collection.id, &req, false)
        .await
        .unwrap();
    let second = refresh_collection(&pool, p.collection.id, &req, false)
        .await
        .unwrap();
    assert_eq!(first.result_version, second.result_version);
    let old = collection_page(&pool, p.collection.id, p.result_version.as_deref(), 1, 1)
        .await
        .unwrap();
    assert_eq!(old.items[0].entity_id, p.items[1].entity_id);
    assert_eq!(
        code(
            collection_page(&pool, p.collection.id, None, 1, 1)
                .await
                .unwrap_err()
        ),
        "collection_invalid"
    );
    close_test_pool(pool, path).await;
}
#[tokio::test]
async fn deleting_user_collection_removes_home_references_atomically() {
    let (pool, path) = fixture().await;
    let p = save(&pool, EntityType::Album, None).await;
    let mut layout = home_layout(&pool).await.unwrap();
    let mut section = layout.sections[0].clone();
    section.id = "custom".into();
    section.collection_id = Some(p.collection.id);
    section.layout = "grid".into();
    layout.sections.push(section);
    save_home_layout(
        &pool,
        &HomeLayoutUpdate {
            expected_revision: layout.revision,
            sections: layout.sections,
        },
    )
    .await
    .unwrap();
    delete_collection(&pool, p.collection.id, p.collection.revision)
        .await
        .unwrap();
    assert!(home_layout(&pool)
        .await
        .unwrap()
        .sections
        .iter()
        .all(|s| s.collection_id != Some(p.collection.id)));
    close_test_pool(pool, path).await;
}
#[tokio::test]
async fn source_rules_follow_inventory_not_heartbeat_and_retired_sources_disappear() {
    let (pool, path) = fixture().await;
    let source = upsert_client_library_manifest(
        &pool,
        &super::collection_sources::source_manifest("phone", "music", "Phone song"),
    )
    .await
    .unwrap();
    let p = save(
        &pool,
        EntityType::Track,
        Some(field("source_ids", "in", json!([source.root_id]))),
    )
    .await;
    assert_eq!(p.result_total, 1);
    let item = match &p.items[0].entity {
        CollectionEntity::Track(t) => t,
        _ => panic!(),
    };
    assert!(
        !item.is_available,
        "inventory does not grant online presence"
    );
    manage_library_source(&pool, source.root_id, "remove")
        .await
        .unwrap();
    let preview = preview_collection(&pool, &p.definition, false)
        .await
        .unwrap();
    assert_eq!(preview["result_total"], 0);
    close_test_pool(pool, path).await;
}
#[tokio::test]
async fn fractional_quantifier_and_null_values_have_explicit_semantics() {
    let (pool, path) = fixture().await;
    let p = save(
        &pool,
        EntityType::Album,
        Some(CollectionPredicate::Tracks {
            quantifier: TrackQuantifier::Percent,
            value: 75,
            role: ArtistTrackRole::Performer,
            condition: Box::new(field("favorite", "eq", json!(true))),
        }),
    )
    .await;
    assert_eq!(p.result_total, 1);
    let unrated = save(
        &pool,
        EntityType::Track,
        Some(field("rating", "eq", json!(0))),
    )
    .await;
    assert_eq!(unrated.result_total, 0);
    let missing = save(
        &pool,
        EntityType::Track,
        Some(field("rating", "is_empty", json!(true))),
    )
    .await;
    assert_eq!(missing.result_total, 3);
    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn six_thousand_members_page_without_truncation_and_play_as_one_snapshot() {
    let (pool, path) = fixture().await;
    let now = Utc::now().to_rfc3339();
    let mut tx = pool.begin().await.unwrap();
    sqlx::query("WITH RECURSIVE ids(i) AS (SELECT 1000 UNION ALL SELECT i+1 FROM ids WHERE i<6999) INSERT INTO files(id,library_root_id,path,relative_path,extension,size_bytes,modified_at,scan_status,created_at,updated_at) SELECT i,1,'/music/bulk-'||i||'.flac','bulk-'||i||'.flac','flac',1024,?1,'ready',?1,?1 FROM ids").bind(&now).execute(&mut *tx).await.unwrap();
    sqlx::query("INSERT INTO tracks(id,file_id,title,album_id,duration_ms,created_at,updated_at) SELECT id,id,'Bulk '||id,1,180000,?1,?1 FROM files WHERE id>=1000").bind(&now).execute(&mut *tx).await.unwrap();
    sqlx::query("INSERT INTO release_tracks(id,global_id,recording_id,title,duration_ms,created_at,updated_at) SELECT id,'bulk-'||id,(SELECT recording_id FROM release_tracks LIMIT 1),title,180000,?1,?1 FROM tracks WHERE id>=1000").bind(&now).execute(&mut *tx).await.unwrap();
    sqlx::query("INSERT INTO track_catalog_links(track_id,release_track_id,release_identity_id,created_at,updated_at) SELECT id,id,id,?1,?1 FROM tracks WHERE id>=1000").bind(&now).execute(&mut *tx).await.unwrap();
    // Repeated appearances of a recording in distinct release slots still count
    // separately. Physical encoding count must not cap or multiply the result.
    sqlx::query("INSERT INTO release_track_media_variants(release_track_id,media_variant_id,is_preferred,created_at) SELECT id,(SELECT media_variant_id FROM release_track_media_variants LIMIT 1),1,?1 FROM tracks WHERE id>=1000").bind(&now).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    let started = std::time::Instant::now();
    let page = save(
        &pool,
        EntityType::Track,
        Some(field("name", "contains", json!("Bulk"))),
    )
    .await;
    assert_eq!(page.result_total, 6000);
    assert_eq!(page.items.len(), 50);
    let version = page.result_version.unwrap();
    let mut ids = std::collections::HashSet::new();
    for offset in (0..6000).step_by(200) {
        let page = collection_page(&pool, page.collection.id, Some(&version), offset, 200)
            .await
            .unwrap();
        assert_eq!(page.items.len(), 200);
        for item in page.items {
            assert!(ids.insert(item.entity_id));
        }
    }
    assert_eq!(ids.len(), 6000);
    let plan = collection_play_plan(
        &pool,
        page.collection.id,
        &CollectionPlayRequest {
            result_version: version,
            entity_ids: None,
        },
        false,
    )
    .await
    .unwrap();
    assert_eq!(plan.tracks.len(), 6000);
    assert_eq!(plan.missing_count, 0);
    eprintln!(
        "6000-member generation, pagination and play plan: {:?}",
        started.elapsed()
    );
    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn daily_and_manual_batches_stay_frozen_while_live_results_follow_changes() {
    let (pool, path) = fixture().await;
    refresh_stale_collections(&pool, false).await.unwrap();
    let daily = list_collections(&pool)
        .await
        .unwrap()
        .into_iter()
        .find(|c| c.system_key.as_deref() == Some("daily_mix"))
        .unwrap();
    let mut manual = save(
        &pool,
        EntityType::Track,
        Some(field("favorite", "eq", json!(true))),
    )
    .await;
    manual.definition.refresh = CollectionRefreshPolicy::Manual;
    let manual = save_collection(
        &pool,
        Some(manual.collection.id),
        &CollectionWrite {
            expected_revision: Some(manual.collection.revision),
            definition: manual.definition,
        },
        false,
    )
    .await
    .unwrap();
    let live = save(
        &pool,
        EntityType::Track,
        Some(field("favorite", "eq", json!(true))),
    )
    .await;
    set_track_favorite(
        &pool,
        2,
        TrackFavoriteUpdate {
            is_favorite: true,
            user_rating: None,
        },
    )
    .await
    .unwrap();
    refresh_stale_collections(&pool, false).await.unwrap();
    assert_eq!(
        collection_page(&pool, daily.id, None, 0, 50)
            .await
            .unwrap()
            .result_version,
        daily.result_version
    );
    assert_eq!(
        collection_page(&pool, manual.collection.id, None, 0, 50)
            .await
            .unwrap()
            .result_version,
        manual.result_version
    );
    let changed = collection_page(&pool, live.collection.id, None, 0, 50)
        .await
        .unwrap();
    assert_ne!(changed.result_version, live.result_version);
    assert_eq!(changed.result_total, 3);
    close_test_pool(pool, path).await;
}

#[tokio::test]
async fn concurrent_retries_of_one_refresh_publish_exactly_one_batch() {
    let (pool, path) = fixture().await;
    let page = save(&pool, EntityType::Track, Some(all(vec![]))).await;
    let request = CollectionRefreshRequest {
        expected_result_version: page.result_version,
        request_id: "same-refresh".into(),
    };
    let (a, b) = tokio::join!(
        refresh_collection(&pool, page.collection.id, &request, false),
        refresh_collection(&pool, page.collection.id, &request, false)
    );
    assert_eq!(a.unwrap().result_version, b.unwrap().result_version);
    let count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM collection_results WHERE collection_id=?1")
            .bind(page.collection.id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(count, 2);
    close_test_pool(pool, path).await;
}
