use super::*;

pub(crate) async fn track_artist_role_names(
    pool: &DbPool,
    track_id: i64,
    role: &str,
) -> Result<Vec<String>> {
    Ok(sqlx::query(
        r#"
        SELECT ar.name
        FROM track_artists ta
        JOIN artists ar ON ar.id = ta.artist_id
        WHERE ta.track_id = ?1 AND ta.role = ?2
        ORDER BY ta.position, ar.name
        "#,
    )
    .bind(track_id)
    .bind(role)
    .fetch_all(pool)
    .await?
    .into_iter()
    .map(|row| row.try_get("name"))
    .collect::<Result<Vec<String>, sqlx::Error>>()?)
}

pub(crate) fn row_to_library_root(row: sqlx::sqlite::SqliteRow) -> Result<LibraryRoot> {
    Ok(LibraryRoot {
        id: row.try_get("id")?,
        path: row.try_get("path")?,
        enabled: row.try_get::<i64, _>("enabled")? != 0,
        created_at: parse_datetime(row.try_get::<String, _>("created_at")?)?,
        updated_at: parse_datetime(row.try_get::<String, _>("updated_at")?)?,
    })
}

pub(crate) fn row_to_album(row: sqlx::sqlite::SqliteRow) -> Result<AlbumSummary> {
    Ok(AlbumSummary {
        id: row.try_get("id")?,
        title: row.try_get("title")?,
        album_artist_display: row.try_get("album_artist_display")?,
        date: row.try_get("date")?,
        year: row.try_get("year")?,
        total_discs: row.try_get("total_discs")?,
        track_count: row.try_get("track_count")?,
        cover_asset_id: row.try_get("cover_asset_id")?,
    })
}

pub(crate) fn row_to_artist(row: sqlx::sqlite::SqliteRow) -> Result<ArtistSummary> {
    Ok(ArtistSummary {
        id: row.try_get("id")?,
        name: row.try_get("name")?,
        sort_name: row.try_get("sort_name")?,
        track_count: row.try_get("track_count")?,
        album_count: row.try_get("album_count")?,
        artwork_revision: row.try_get("artwork_revision")?,
        has_artwork: row.try_get::<i64, _>("has_artwork")? != 0,
    })
}

pub(crate) fn row_to_track(row: sqlx::sqlite::SqliteRow) -> Result<TrackSummary> {
    Ok(TrackSummary {
        id: row.try_get("id")?,
        file_id: row.try_get("file_id")?,
        album_id: row.try_get("album_id")?,
        title: row.try_get("title")?,
        artist_display: row.try_get("artist_display")?,
        album_title: row.try_get("album_title")?,
        disc_number: row.try_get("disc_number")?,
        track_number: row.try_get("track_number")?,
        duration_ms: row.try_get("duration_ms")?,
        year: row.try_get("year")?,
        cover_asset_id: row.try_get("cover_asset_id")?,
        is_favorite: row.try_get::<i64, _>("is_favorite")? != 0,
        user_rating: row.try_get("user_rating")?,
        tag_rating: row.try_get("tag_rating")?,
        tag_rating_scale: row.try_get("tag_rating_scale")?,
        effective_rating: row.try_get("effective_rating")?,
        size_bytes: row.try_get("size_bytes")?,
        added_at: parse_datetime(row.try_get::<String, _>("added_at")?)?,
        play_count: row.try_get("play_count")?,
    })
}

pub(crate) fn row_to_playlist_summary(
    row: sqlx::sqlite::SqliteRow,
    track_count: i64,
) -> Result<PlaylistSummary> {
    Ok(PlaylistSummary {
        id: row.try_get("id")?,
        name: row.try_get("name")?,
        kind: parse_playlist_kind(&row.try_get::<String, _>("kind")?),
        description: row.try_get("description")?,
        track_count,
        created_at: parse_datetime(row.try_get::<String, _>("created_at")?)?,
        updated_at: parse_datetime(row.try_get::<String, _>("updated_at")?)?,
    })
}

pub(crate) async fn manual_playlist_tracks(
    pool: &DbPool,
    playlist_id: i64,
) -> Result<Vec<TrackSummary>> {
    let rows = sqlx::query(
        track_select_sql(
            r#"
            JOIN playlist_items pi ON t.id = COALESCE(
                (
                    SELECT member.canonical_track_id
                    FROM track_merge_members member
                    WHERE member.track_id = pi.track_id
                ),
                pi.track_id
            )
            WHERE pi.playlist_id = ?1
            GROUP BY t.id, pi.id
            ORDER BY pi.position, pi.id
            "#,
        )
        .as_str(),
    )
    .bind(playlist_id)
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(row_to_track).collect()
}

pub(crate) async fn ensure_manual_playlist(pool: &DbPool, playlist_id: i64) -> Result<()> {
    let kind: String = sqlx::query("SELECT kind FROM playlists WHERE id = ?1")
        .bind(playlist_id)
        .fetch_one(pool)
        .await?
        .try_get("kind")?;
    if kind != "manual" {
        anyhow::bail!("smart playlists are rule based and cannot be edited manually");
    }
    Ok(())
}

pub(crate) async fn next_playlist_position(pool: &DbPool, playlist_id: i64) -> Result<i64> {
    let position = sqlx::query(
        "SELECT COALESCE(MAX(position), -1) + 1 AS position FROM playlist_items WHERE playlist_id = ?1",
    )
    .bind(playlist_id)
    .fetch_one(pool)
    .await?
    .try_get("position")?;
    Ok(position)
}

pub(crate) async fn compact_playlist_positions(pool: &DbPool, playlist_id: i64) -> Result<()> {
    let item_ids =
        sqlx::query("SELECT id FROM playlist_items WHERE playlist_id = ?1 ORDER BY position, id")
            .bind(playlist_id)
            .fetch_all(pool)
            .await?
            .into_iter()
            .map(|row| row.try_get::<i64, _>("id"))
            .collect::<Result<Vec<_>, _>>()?;

    for (position, item_id) in item_ids.into_iter().enumerate() {
        sqlx::query("UPDATE playlist_items SET position = ?1 WHERE id = ?2")
            .bind(position as i64)
            .bind(item_id)
            .execute(pool)
            .await?;
    }
    Ok(())
}

pub(crate) async fn smart_playlist_tracks(
    pool: &DbPool,
    rules: Option<&Value>,
    limit: u32,
    offset: u32,
    include_max_tag_rating_as_favorite: bool,
) -> Result<Vec<TrackSummary>> {
    let mut query = QueryBuilder::<Sqlite>::new("");
    push_track_select_builder(&mut query);
    let has_rules = !smart_rule_values(rules).is_empty();
    push_smart_where(&mut query, rules, include_max_tag_rating_as_favorite);
    push_visible_recording_filter(&mut query, has_rules);
    query.push(" GROUP BY t.id ORDER BY t.title COLLATE NOCASE LIMIT ");
    query.push_bind(limit.clamp(1, 5000) as i64);
    query.push(" OFFSET ");
    query.push_bind(offset as i64);

    let rows = query.build().fetch_all(pool).await?;
    rows.into_iter().map(row_to_track).collect()
}

pub(crate) async fn smart_playlist_track_count(
    pool: &DbPool,
    rules: Option<&Value>,
    include_max_tag_rating_as_favorite: bool,
) -> Result<i64> {
    let mut query = QueryBuilder::<Sqlite>::new("SELECT COUNT(DISTINCT t.id) AS count");
    push_track_from_joins(&mut query);
    let has_rules = !smart_rule_values(rules).is_empty();
    push_smart_where(&mut query, rules, include_max_tag_rating_as_favorite);
    push_visible_recording_filter(&mut query, has_rules);
    Ok(query
        .build()
        .fetch_one(pool)
        .await?
        .try_get::<i64, _>("count")?)
}

fn push_visible_recording_filter(query: &mut QueryBuilder<'_, Sqlite>, has_where: bool) {
    query.push(if has_where { " AND " } else { " WHERE " });
    query.push(
        r#"
        NOT EXISTS (
            SELECT 1 FROM track_merge_members member
            WHERE member.track_id = t.id
        )
        AND (
            NOT EXISTS (
                SELECT 1 FROM legacy_track_catalog_links missing_link
                WHERE missing_link.track_id = t.id
            )
            OR t.id = (
                SELECT MIN(candidate.track_id)
                FROM legacy_track_catalog_links candidate
                JOIN release_tracks candidate_release
                  ON candidate_release.id = candidate.release_track_id
                LEFT JOIN track_merge_members member
                  ON member.track_id = candidate.track_id
                WHERE member.track_id IS NULL
                  AND candidate_release.recording_id = (
                    SELECT current_release.recording_id
                    FROM legacy_track_catalog_links current_link
                    JOIN release_tracks current_release
                      ON current_release.id = current_link.release_track_id
                    WHERE current_link.track_id = t.id
                  )
            )
        )
        "#,
    );
}

pub(crate) fn push_track_select_builder(query: &mut QueryBuilder<'_, Sqlite>) {
    query.push(
        r#"
        SELECT
            t.id, t.file_id, t.album_id, t.title,
            COALESCE(GROUP_CONCAT(DISTINCT ar.name), NULL) AS artist_display,
            al.title AS album_title,
            t.disc_number, t.track_number, t.duration_ms, t.year, t.cover_asset_id,
            COALESCE(uts.is_favorite, 0) AS is_favorite,
            uts.user_rating,
            t.tag_rating,
            t.tag_rating_scale,
            COALESCE(
                uts.user_rating,
                CASE
                    WHEN t.tag_rating IS NOT NULL
                     AND t.tag_rating_scale IS NOT NULL
                     AND t.tag_rating_scale > 0
                    THEN CAST(ROUND(t.tag_rating * 100.0 / t.tag_rating_scale) AS INTEGER)
                    ELSE NULL
                END
            ) AS effective_rating,
            f.size_bytes AS size_bytes,
            f.created_at AS added_at,
            (
                SELECT COUNT(*)
                FROM playback_sessions ps
                WHERE ps.track_id = t.id
                   OR ps.track_id IN (
                        SELECT member.track_id
                        FROM track_merge_members member
                        WHERE member.canonical_track_id = t.id
                   )
            ) AS play_count
        "#,
    );
    push_track_from_joins(query);
}

pub(crate) fn push_track_from_joins(query: &mut QueryBuilder<'_, Sqlite>) {
    query.push(
        r#"
        FROM tracks t
        LEFT JOIN albums al ON al.id = t.album_id
        LEFT JOIN track_artists ta ON ta.track_id = t.id AND ta.role = 'primary'
        LEFT JOIN artists ar ON ar.id = ta.artist_id
        LEFT JOIN user_track_state uts ON uts.track_id = t.id
        LEFT JOIN files f ON f.id = t.file_id
        "#,
    );
}

pub(crate) fn push_smart_where(
    query: &mut QueryBuilder<'_, Sqlite>,
    rules: Option<&Value>,
    include_max_tag_rating_as_favorite: bool,
) {
    let rule_values = smart_rule_values(rules);
    if rule_values.is_empty() {
        return;
    }

    let match_any = smart_match_any(rules);
    query.push(" WHERE ");
    query.push(if match_any { "0 = 1" } else { "1 = 1" });
    for rule in rule_values {
        query.push(if match_any { " OR " } else { " AND " });
        if !push_smart_rule(query, rule, include_max_tag_rating_as_favorite) {
            query.push(if match_any { "0 = 1" } else { "1 = 1" });
        }
    }
}

pub(crate) fn smart_rule_values(rules: Option<&Value>) -> Vec<&Value> {
    let Some(rules) = rules else {
        return Vec::new();
    };
    if let Some(array) = rules.as_array() {
        return array.iter().collect();
    }
    if let Some(array) = rules.get("rules").and_then(Value::as_array) {
        return array.iter().collect();
    }
    if rules.is_object() {
        return vec![rules];
    }
    Vec::new()
}

pub(crate) fn smart_match_any(rules: Option<&Value>) -> bool {
    rules
        .and_then(|value| value.get("match").or_else(|| value.get("mode")))
        .and_then(Value::as_str)
        .map(|value| matches!(value.to_ascii_lowercase().as_str(), "any" | "or"))
        .unwrap_or(false)
}

pub(crate) fn push_smart_rule(
    query: &mut QueryBuilder<'_, Sqlite>,
    rule: &Value,
    include_max_tag_rating_as_favorite: bool,
) -> bool {
    let field = rule
        .get("field")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    let operator = rule
        .get("op")
        .or_else(|| rule.get("operator"))
        .and_then(Value::as_str)
        .unwrap_or("contains")
        .to_ascii_lowercase();
    let value = rule.get("value").unwrap_or(&Value::Null);

    match field.as_str() {
        "title" | "track" => push_text_rule(query, "t.title", &operator, value),
        "album" => push_text_rule(query, "al.title", &operator, value),
        "album_artist" => push_text_rule(query, "al.album_artist_display", &operator, value),
        "artist" => push_exists_text_rule(
            query,
            r#"EXISTS (
                SELECT 1
                FROM track_artists ta2
                JOIN artists ar2 ON ar2.id = ta2.artist_id
                WHERE ta2.track_id = t.id AND ta2.role = 'primary' AND "#,
            "ar2.name",
            &operator,
            value,
        ),
        "composer" => push_exists_text_rule(
            query,
            r#"EXISTS (
                SELECT 1
                FROM track_artists ta2
                JOIN artists ar2 ON ar2.id = ta2.artist_id
                WHERE ta2.track_id = t.id AND ta2.role = 'composer' AND "#,
            "ar2.name",
            &operator,
            value,
        ),
        "lyricist" | "writer" => push_exists_text_rule(
            query,
            r#"EXISTS (
                SELECT 1
                FROM track_artists ta2
                JOIN artists ar2 ON ar2.id = ta2.artist_id
                WHERE ta2.track_id = t.id AND ta2.role = 'lyricist' AND "#,
            "ar2.name",
            &operator,
            value,
        ),
        "genre" => push_exists_text_rule(
            query,
            r#"EXISTS (
                SELECT 1
                FROM track_genres tg2
                JOIN genres g2 ON g2.id = tg2.genre_id
                WHERE tg2.track_id = t.id AND "#,
            "g2.name",
            &operator,
            value,
        ),
        "extension" | "format" => push_text_rule(query, "f.extension", &operator, value),
        "path" | "file" => push_text_rule(query, "f.path", &operator, value),
        "year" => push_number_rule(query, "t.year", &operator, value),
        "duration_ms" | "duration" => push_number_rule(query, "t.duration_ms", &operator, value),
        "rating" | "effective_rating" => {
            push_number_rule(query, effective_rating_expr(), &operator, value)
        }
        "tag_rating" => push_number_rule(query, "t.tag_rating", &operator, value),
        "favorite" | "favourite" => {
            let expression = if include_max_tag_rating_as_favorite {
                favorite_with_tag_rating_expr()
            } else {
                "COALESCE(uts.is_favorite, 0)"
            };
            push_bool_rule(query, expression, value)
        }
        "library_source" | "source" => push_library_source_rule(query, &operator, value),
        _ => false,
    }
}

pub(crate) fn favorite_with_tag_rating_expr() -> &'static str {
    r#"
    (
        COALESCE(uts.is_favorite, 0) = 1
        OR (
            t.tag_rating IS NOT NULL
            AND t.tag_rating_scale IS NOT NULL
            AND t.tag_rating_scale > 0
            AND t.tag_rating >= t.tag_rating_scale
        )
    )
    "#
}

pub(crate) fn push_exists_text_rule(
    query: &mut QueryBuilder<'_, Sqlite>,
    prefix: &str,
    column: &str,
    operator: &str,
    value: &Value,
) -> bool {
    let Some(text) = value_to_string(value) else {
        return false;
    };
    query.push(prefix);
    push_text_condition(query, column, operator, &text);
    query.push(")");
    true
}

pub(crate) fn push_text_rule(
    query: &mut QueryBuilder<'_, Sqlite>,
    column: &str,
    operator: &str,
    value: &Value,
) -> bool {
    let Some(text) = value_to_string(value) else {
        return false;
    };
    push_text_condition(query, column, operator, &text);
    true
}

pub(crate) fn push_text_condition(
    query: &mut QueryBuilder<'_, Sqlite>,
    column: &str,
    operator: &str,
    value: &str,
) {
    let normalized = value.to_ascii_lowercase();
    query.push("LOWER(COALESCE(");
    query.push(column);
    query.push(", '')) ");
    match operator {
        "equals" | "is" | "=" | "==" => {
            query.push("= ");
            query.push_bind(normalized);
        }
        "not_equals" | "!=" => {
            query.push("!= ");
            query.push_bind(normalized);
        }
        "starts_with" => {
            query.push("LIKE ");
            query.push_bind(format!("{normalized}%"));
        }
        "ends_with" => {
            query.push("LIKE ");
            query.push_bind(format!("%{normalized}"));
        }
        "not_contains" => {
            query.push("NOT LIKE ");
            query.push_bind(format!("%{normalized}%"));
        }
        _ => {
            query.push("LIKE ");
            query.push_bind(format!("%{normalized}%"));
        }
    }
}

pub(crate) fn push_number_rule(
    query: &mut QueryBuilder<'_, Sqlite>,
    expression: &str,
    operator: &str,
    value: &Value,
) -> bool {
    let Some(number) = value_to_i64(value) else {
        return false;
    };
    query.push("(");
    query.push(expression);
    query.push(") ");
    match operator {
        "gt" | ">" => query.push("> "),
        "gte" | ">=" => query.push(">= "),
        "lt" | "<" => query.push("< "),
        "lte" | "<=" => query.push("<= "),
        "not_equals" | "!=" => query.push("!= "),
        _ => query.push("= "),
    };
    query.push_bind(number);
    true
}

pub(crate) fn push_bool_rule(
    query: &mut QueryBuilder<'_, Sqlite>,
    expression: &str,
    value: &Value,
) -> bool {
    let Some(value) = value_to_bool(value) else {
        return false;
    };
    query.push("(");
    query.push(expression);
    query.push(") = ");
    query.push_bind(if value { 1_i64 } else { 0_i64 });
    true
}

pub(crate) fn value_to_string(value: &Value) -> Option<String> {
    match value {
        Value::String(value) => Some(value.trim().to_string()).filter(|value| !value.is_empty()),
        Value::Number(value) => Some(value.to_string()),
        Value::Bool(value) => Some(value.to_string()),
        _ => None,
    }
}

pub(crate) fn value_to_i64(value: &Value) -> Option<i64> {
    match value {
        Value::Number(value) => value
            .as_i64()
            .or_else(|| value.as_f64().map(|value| value as i64)),
        Value::String(value) => value.trim().parse::<i64>().ok(),
        _ => None,
    }
}

pub(crate) fn value_to_bool(value: &Value) -> Option<bool> {
    match value {
        Value::Bool(value) => Some(*value),
        Value::Number(value) => Some(value.as_i64()? != 0),
        Value::String(value) => match value.trim().to_ascii_lowercase().as_str() {
            "true" | "yes" | "1" | "favorite" | "favourite" => Some(true),
            "false" | "no" | "0" => Some(false),
            _ => None,
        },
        _ => None,
    }
}

pub(crate) fn parse_rules_json(value: Option<&str>) -> Result<Option<Value>> {
    value
        .filter(|value| !value.trim().is_empty())
        .map(serde_json::from_str)
        .transpose()
        .map_err(Into::into)
}

pub(crate) fn playlist_kind_as_str(kind: &PlaylistKind) -> &'static str {
    match kind {
        PlaylistKind::Manual => "manual",
        PlaylistKind::Smart => "smart",
    }
}

pub(crate) fn parse_playlist_kind(value: &str) -> PlaylistKind {
    if value == "smart" {
        PlaylistKind::Smart
    } else {
        PlaylistKind::Manual
    }
}

pub(crate) fn effective_rating_expr() -> &'static str {
    r#"
    COALESCE(
        uts.user_rating,
        CASE
            WHEN t.tag_rating IS NOT NULL
             AND t.tag_rating_scale IS NOT NULL
             AND t.tag_rating_scale > 0
            THEN CAST(ROUND(t.tag_rating * 100.0 / t.tag_rating_scale) AS INTEGER)
            ELSE NULL
        END
    )
    "#
}

pub(crate) fn row_to_playback_event(row: sqlx::sqlite::SqliteRow) -> Result<PlaybackEvent> {
    Ok(PlaybackEvent {
        id: row.try_get("id")?,
        zone_id: row.try_get("zone_id")?,
        event_type: row.try_get("event_type")?,
        track_id: row.try_get("track_id")?,
        track_title: row.try_get("track_title")?,
        position_ms: row
            .try_get::<Option<i64>, _>("position_ms")?
            .map(|value| value as u64),
        related_zone_id: row.try_get("related_zone_id")?,
        reason: row.try_get("reason")?,
        created_at: parse_datetime(row.try_get::<String, _>("created_at")?)?,
    })
}

pub(crate) fn row_to_playback_session(row: sqlx::sqlite::SqliteRow) -> Result<PlaybackSession> {
    Ok(PlaybackSession {
        id: row.try_get("id")?,
        zone_id: row.try_get("zone_id")?,
        track_id: row.try_get("track_id")?,
        track_title: row.try_get("track_title")?,
        started_at: parse_datetime(row.try_get::<String, _>("started_at")?)?,
        start_position_ms: row.try_get::<i64, _>("start_position_ms")? as u64,
        ended_at: row
            .try_get::<Option<String>, _>("ended_at")?
            .map(parse_datetime)
            .transpose()?,
        end_position_ms: row
            .try_get::<Option<i64>, _>("end_position_ms")?
            .map(|value| value as u64),
        end_reason: row.try_get("end_reason")?,
        played_ms: row.try_get::<i64, _>("played_ms")? as u64,
    })
}

pub(crate) fn row_to_track_playback_stat(
    row: sqlx::sqlite::SqliteRow,
) -> Result<TrackPlaybackStat> {
    Ok(TrackPlaybackStat {
        track_id: row.try_get("track_id")?,
        title: row.try_get("title")?,
        artist_display: row.try_get("artist_display")?,
        album_title: row.try_get("album_title")?,
        play_count: row.try_get("play_count")?,
        total_played_ms: row.try_get::<i64, _>("total_played_ms")? as u64,
        last_played_at: row
            .try_get::<Option<String>, _>("last_played_at")?
            .map(parse_datetime)
            .transpose()?,
    })
}

pub(crate) async fn get_playback_event(pool: &DbPool, id: i64) -> Result<PlaybackEvent> {
    let row = sqlx::query(
        r#"
        SELECT id, zone_id, event_type, track_id, track_title, position_ms,
               related_zone_id, reason, created_at
        FROM playback_events
        WHERE id = ?1
        "#,
    )
    .bind(id)
    .fetch_one(pool)
    .await?;
    row_to_playback_event(row)
}

pub(crate) async fn get_playback_session(pool: &DbPool, id: i64) -> Result<PlaybackSession> {
    let row = sqlx::query(
        r#"
        SELECT id, zone_id, track_id, track_title, started_at, start_position_ms,
               ended_at, end_position_ms, end_reason, played_ms
        FROM playback_sessions
        WHERE id = ?1
        "#,
    )
    .bind(id)
    .fetch_one(pool)
    .await?;
    row_to_playback_session(row)
}

pub(crate) async fn open_playback_session_id(pool: &DbPool, zone_id: &str) -> Result<Option<i64>> {
    Ok(sqlx::query(
        r#"
        SELECT id
        FROM playback_sessions
        WHERE zone_id = ?1 AND ended_at IS NULL
        ORDER BY started_at DESC
        LIMIT 1
        "#,
    )
    .bind(zone_id)
    .fetch_optional(pool)
    .await?
    .map(|row| row.try_get::<i64, _>("id"))
    .transpose()?)
}

pub(crate) fn track_select_sql(tail: &str) -> String {
    track_select_sql_extra("", tail)
}

pub(crate) fn track_select_sql_extra(extra_select: &str, tail: &str) -> String {
    format!(
        r#"
        SELECT
            {extra_select}
            t.id, t.file_id, t.album_id, t.title,
            COALESCE(GROUP_CONCAT(DISTINCT ar.name), NULL) AS artist_display,
            al.title AS album_title,
            t.disc_number, t.track_number, t.duration_ms, t.year, t.cover_asset_id,
            COALESCE(uts.is_favorite, 0) AS is_favorite,
            uts.user_rating,
            t.tag_rating,
            t.tag_rating_scale,
            COALESCE(
                uts.user_rating,
                CASE
                    WHEN t.tag_rating IS NOT NULL
                     AND t.tag_rating_scale IS NOT NULL
                     AND t.tag_rating_scale > 0
                    THEN CAST(ROUND(t.tag_rating * 100.0 / t.tag_rating_scale) AS INTEGER)
                    ELSE NULL
                END
            ) AS effective_rating,
            f.size_bytes AS size_bytes,
            f.created_at AS added_at,
            (
                SELECT COUNT(*)
                FROM playback_sessions ps
                WHERE ps.track_id = t.id
                   OR ps.track_id IN (
                        SELECT member.track_id
                        FROM track_merge_members member
                        WHERE member.canonical_track_id = t.id
                   )
            ) AS play_count
        FROM tracks t
        JOIN files f ON f.id = t.file_id
        LEFT JOIN albums al ON al.id = t.album_id
        LEFT JOIN track_artists ta ON ta.track_id = t.id AND ta.role = 'primary'
        LEFT JOIN artists ar ON ar.id = ta.artist_id
        LEFT JOIN user_track_state uts ON uts.track_id = t.id
        {tail}
        "#
    )
}

pub(crate) fn parse_datetime(value: String) -> Result<DateTime<Utc>> {
    if let Ok(value) = DateTime::parse_from_rfc3339(&value) {
        return Ok(value.with_timezone(&Utc));
    }
    Ok(Utc::now())
}

pub fn normalize_path(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

pub fn normalize_text(value: &str) -> String {
    value.trim().to_lowercase()
}

pub(crate) fn album_key(
    album_artist: &str,
    album_title: &str,
    year: Option<i64>,
    library_root_id: i64,
) -> String {
    format!(
        "{}\0{}\0{}\0{}",
        normalize_text(album_artist),
        normalize_text(album_title),
        year.map(|year| year.to_string()).unwrap_or_default(),
        library_root_id
    )
}
