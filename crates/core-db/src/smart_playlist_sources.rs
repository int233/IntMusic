use super::*;

pub(crate) fn push_library_source_rule(
    query: &mut QueryBuilder<'_, Sqlite>,
    operator: &str,
    value: &Value,
) -> bool {
    let source_ids = match value {
        Value::Array(values) => values.iter().filter_map(value_to_i64).collect::<Vec<_>>(),
        _ => value_to_i64(value).into_iter().collect::<Vec<_>>(),
    };
    if source_ids.is_empty() {
        return false;
    }

    match operator {
        "in_all" => {
            query.push("(");
            for (index, source_id) in source_ids.iter().enumerate() {
                if index > 0 {
                    query.push(" AND ");
                }
                push_library_source_exists(query, &[*source_id], false);
            }
            query.push(")");
        }
        "not_in" => {
            query.push("NOT ");
            push_library_source_exists(query, &source_ids, false);
        }
        "only_in" => {
            query.push("(");
            push_library_source_exists(query, &source_ids, false);
            query.push(" AND NOT ");
            push_library_source_exists(query, &source_ids, true);
            query.push(")");
        }
        _ => push_library_source_exists(query, &source_ids, false),
    }
    true
}

fn push_library_source_exists(
    query: &mut QueryBuilder<'_, Sqlite>,
    source_ids: &[i64],
    outside_selection: bool,
) {
    query.push(
        r#"EXISTS (
            SELECT 1
            FROM media_replicas source_replica
            LEFT JOIN files source_file ON source_file.id = source_replica.file_id
            JOIN library_roots source_root
              ON source_root.id = COALESCE(
                  source_replica.library_root_id,
                  source_file.library_root_id
              )
            LEFT JOIN devices source_device ON source_device.id = source_root.owner_device_id
            WHERE source_replica.availability_state NOT IN ('retired', 'ignored')
              AND (source_file.id IS NULL OR source_file.deleted_at IS NULL)
              AND source_root.enabled = 1
              AND source_root.retired_at IS NULL
              AND source_root.removed_at IS NULL
              AND (
                  source_device.id IS NULL
                  OR (
                      source_device.retired_at IS NULL
                      AND source_device.removed_at IS NULL
                  )
              )
              AND (
                  source_replica.file_id = t.file_id
                  OR source_replica.media_variant_id IN (
                      SELECT related_variant.media_variant_id
                      FROM legacy_track_catalog_links current_link
                      JOIN release_tracks current_release
                        ON current_release.id = current_link.release_track_id
                      JOIN release_tracks related_release
                        ON related_release.recording_id = current_release.recording_id
                      JOIN release_track_media_variants related_variant
                        ON related_variant.release_track_id = related_release.id
                      WHERE current_link.track_id = t.id
                  )
              )
              AND source_root.id "#,
    );
    query.push(if outside_selection {
        "NOT IN ("
    } else {
        "IN ("
    });
    {
        let mut separated = query.separated(", ");
        for source_id in source_ids {
            separated.push_bind(*source_id);
        }
    }
    query.push("))");
}
