-- Album identity belongs to the catalog, not to a library root. Older builds
-- intentionally included the root ID in albums.album_key, which created one
-- album row per Core or Client source. Keep those rows for referential and
-- history safety, but expose a stable canonical identity for catalog queries.

CREATE VIEW IF NOT EXISTS album_identity_members AS
WITH album_identities AS (
    SELECT
        album.id AS album_id,
        lower(trim(album.title)) AS title_key,
        COALESCE(
            NULLIF(
                (
                    SELECT GROUP_CONCAT(ordered_artist.normalized_name, char(30))
                    FROM (
                        SELECT artist.normalized_name
                        FROM album_artists credit
                        JOIN artists artist ON artist.id = credit.artist_id
                        WHERE credit.album_id = album.id
                        ORDER BY artist.normalized_name
                    ) ordered_artist
                ),
                ''
            ),
            lower(trim(COALESCE(album.album_artist_display, '')))
        ) AS artist_key,
        COALESCE(CAST(album.year AS TEXT), '') AS year_key
    FROM albums album
), keyed AS (
    SELECT
        album_id,
        title_key || char(31) || artist_key || char(31) || year_key AS identity_key
    FROM album_identities
)
SELECT
    album_id,
    identity_key,
    MIN(album_id) OVER (PARTITION BY identity_key) AS canonical_album_id
FROM keyed;

-- A catalog track remains visible while at least one current Core or Client
-- replica still exists. Offline devices remain valid; removed roots, removed
-- devices, deleted files, and retired/missing replicas do not.
CREATE VIEW IF NOT EXISTS active_catalog_tracks AS
SELECT DISTINCT track.id AS track_id
FROM tracks track
JOIN legacy_track_catalog_links link ON link.track_id = track.id
JOIN release_track_media_variants relation
  ON relation.release_track_id = link.release_track_id
JOIN media_replicas replica ON replica.media_variant_id = relation.media_variant_id
LEFT JOIN files file ON file.id = replica.file_id
LEFT JOIN library_roots root ON root.id = replica.library_root_id
LEFT JOIN devices device ON device.id = replica.device_id
WHERE NOT EXISTS (
        SELECT 1 FROM track_merge_members member
        WHERE member.track_id = track.id
    )
  AND replica.availability_state NOT IN ('retired', 'ignored', 'missing')
  AND (file.id IS NULL OR file.deleted_at IS NULL)
  AND (
      root.id IS NULL
      OR (
          root.removed_at IS NULL
          AND root.retired_at IS NULL
          AND root.enabled = 1
      )
  )
  AND (device.id IS NULL OR device.removed_at IS NULL)
UNION
SELECT track.id AS track_id
FROM tracks track
JOIN files file ON file.id = track.file_id
JOIN library_roots root ON root.id = file.library_root_id
WHERE NOT EXISTS (
        SELECT 1 FROM legacy_track_catalog_links link
        WHERE link.track_id = track.id
    )
  AND NOT EXISTS (
        SELECT 1 FROM track_merge_members member
        WHERE member.track_id = track.id
    )
  AND file.deleted_at IS NULL
  AND root.removed_at IS NULL
  AND root.retired_at IS NULL
  AND root.enabled = 1;
