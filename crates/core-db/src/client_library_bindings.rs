use super::*;

pub async fn client_library_copy_bindings(
    pool: &DbPool,
    device_id: &str,
) -> Result<Vec<ClientLibraryCopyBinding>> {
    // Reuse one visible-catalog projection for the entire device. An inlined
    // view in the file join can otherwise rescan the full catalog per replica.
    let rows = sqlx::query(
        r#"
        WITH visible AS MATERIALIZED (
            SELECT track_id FROM visible_catalog_tracks
        ), variant_tracks AS MATERIALIZED (
            SELECT relation.media_variant_id, MIN(links.track_id) AS track_id
            FROM visible
            JOIN track_catalog_links links ON links.track_id = visible.track_id
            JOIN track_catalog_links source_link
              ON COALESCE(source_link.release_identity_id, source_link.release_track_id)
               = COALESCE(links.release_identity_id, links.release_track_id)
            JOIN release_track_media_variants relation
              ON relation.release_track_id = source_link.release_track_id
            GROUP BY relation.media_variant_id
        )
        SELECT root.external_id AS root_external_id,
            file.client_file_id AS external_id,
            MIN(variant_tracks.track_id) AS track_id,
            replica.media_variant_id
        FROM files file
        JOIN library_roots root ON root.id = file.library_root_id
        JOIN media_replicas replica ON replica.file_id = file.id
        JOIN variant_tracks ON variant_tracks.media_variant_id = replica.media_variant_id
        WHERE root.root_kind = 'client'
          AND root.owner_device_id = ?1
          AND root.enabled = 1
          AND root.retired_at IS NULL
          AND root.removed_at IS NULL
          AND file.client_file_id IS NOT NULL
          AND file.deleted_at IS NULL
          AND file.availability_state = 'ready'
          AND replica.availability_state = 'ready'
        GROUP BY root.external_id, file.client_file_id, replica.media_variant_id
        ORDER BY root.external_id, file.client_file_id
        "#,
    )
    .bind(device_id.trim())
    .fetch_all(pool)
    .await?;
    rows.into_iter()
        .map(|row| {
            Ok(ClientLibraryCopyBinding {
                root_external_id: row.try_get("root_external_id")?,
                external_id: row.try_get("external_id")?,
                track_id: row.try_get("track_id")?,
                media_variant_id: row.try_get("media_variant_id")?,
            })
        })
        .collect()
}
