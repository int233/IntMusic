use super::*;

pub async fn album_detail(pool: &DbPool, album_id: i64) -> Result<AlbumDetail> {
    let album_row = sqlx::query(
        r#"
        SELECT canonical.id,
               COALESCE(NULLIF(profile.title, ''), canonical.title) AS title,
               COALESCE(NULLIF(profile.album_artist_display, ''), canonical.album_artist_display) AS album_artist_display,
               COALESCE(NULLIF(profile.date, ''), canonical.date, MAX(member_album.date)) AS date,
               COALESCE(profile.year, canonical.year, MAX(member_album.year)) AS year,
               COALESCE(profile.total_discs, MAX(member_album.total_discs)) AS total_discs,
               COALESCE(canonical.cover_asset_id, MAX(member_album.cover_asset_id)) AS cover_asset_id,
               COUNT(DISTINCT CASE WHEN member.track_id IS NULL THEN
                   CASE WHEN release_track.recording_id IS NOT NULL THEN
                       'recording:' || release_track.recording_id ||
                       ':disc:' || COALESCE(release_track.disc_number, t.disc_number, 1) ||
                       ':track:' || COALESCE(release_track.track_number, t.track_number, -1)
                   ELSE 'legacy:' || t.id END
               END) AS track_count
        FROM album_identity_members requested
        JOIN album_identity_members identity
          ON identity.canonical_album_id = requested.canonical_album_id
        JOIN albums canonical ON canonical.id = requested.canonical_album_id
        LEFT JOIN album_metadata_profiles profile ON profile.album_id = canonical.id
        JOIN albums member_album ON member_album.id = identity.album_id
        JOIN tracks t ON t.album_id = member_album.id
        JOIN active_catalog_tracks active ON active.track_id = t.id
        LEFT JOIN legacy_track_catalog_links links ON links.track_id = t.id
        LEFT JOIN release_tracks release_track ON release_track.id = links.release_track_id
        LEFT JOIN track_merge_members member ON member.track_id = t.id
        WHERE requested.album_id = ?1
        GROUP BY canonical.id
        "#,
    )
    .bind(album_id)
    .fetch_one(pool)
    .await?;

    let track_rows = sqlx::query(
        track_select_sql(
            r#"
            LEFT JOIN legacy_track_catalog_links current_link ON current_link.track_id = t.id
            LEFT JOIN release_tracks current_release
              ON current_release.id = current_link.release_track_id
            JOIN album_identity_members track_album ON track_album.album_id = t.album_id
            JOIN album_identity_members requested_album
              ON requested_album.album_id = ?1
             AND requested_album.canonical_album_id = track_album.canonical_album_id
            JOIN active_catalog_tracks active ON active.track_id = t.id
            WHERE 1 = 1
              AND NOT EXISTS (
                SELECT 1 FROM track_merge_members member
                WHERE member.track_id = t.id
              )
              AND (
                current_release.id IS NULL
                OR t.id = (
                SELECT MIN(candidate.track_id)
                FROM legacy_track_catalog_links candidate
                JOIN release_tracks candidate_release
                  ON candidate_release.id = candidate.release_track_id
                JOIN tracks candidate_track ON candidate_track.id = candidate.track_id
                JOIN album_identity_members candidate_album
                  ON candidate_album.album_id = candidate_track.album_id
                 AND candidate_album.canonical_album_id = track_album.canonical_album_id
                JOIN active_catalog_tracks candidate_active
                  ON candidate_active.track_id = candidate.track_id
                LEFT JOIN track_merge_members member
                  ON member.track_id = candidate.track_id
                WHERE candidate_release.recording_id = current_release.recording_id
                  AND COALESCE(
                        candidate_release.disc_number,
                        candidate_track.disc_number,
                        1
                      ) = COALESCE(current_release.disc_number, t.disc_number, 1)
                  AND COALESCE(
                        candidate_release.track_number,
                        candidate_track.track_number,
                        -1
                      ) = COALESCE(current_release.track_number, t.track_number, -1)
                  AND member.track_id IS NULL
                )
              )
            GROUP BY t.id
            ORDER BY COALESCE(t.disc_number, 1), COALESCE(t.track_number, 0), t.title
            "#,
        )
        .as_str(),
    )
    .bind(album_id)
    .fetch_all(pool)
    .await?;

    let canonical_id: i64 = album_row.try_get("id")?;
    Ok(AlbumDetail {
        album: row_to_album(album_row)?,
        tracks: track_rows
            .into_iter()
            .map(row_to_track)
            .collect::<Result<_>>()?,
        profile: album_metadata_profile(pool, canonical_id).await?,
        credits: album_credits(pool, canonical_id).await?,
    })
}
