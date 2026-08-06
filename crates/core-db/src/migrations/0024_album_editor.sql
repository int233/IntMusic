-- Album-level editorial metadata is intentionally separate from file tags.
-- Rescans may refresh the source albums, while these manual values, credits,
-- and explicit duplicate-album migrations remain authoritative.

CREATE TABLE album_metadata_profiles (
    album_id INTEGER PRIMARY KEY,
    title TEXT,
    sort_title TEXT,
    subtitle TEXT,
    release_type TEXT,
    edition_title TEXT,
    release_status TEXT,
    date TEXT,
    original_date TEXT,
    year INTEGER,
    total_discs INTEGER,
    country TEXT,
    language TEXT,
    media_format TEXT,
    packaging TEXT,
    barcode TEXT,
    catalog_numbers_json TEXT NOT NULL DEFAULT '[]',
    labels_json TEXT NOT NULL DEFAULT '[]',
    publishers_json TEXT NOT NULL DEFAULT '[]',
    genres_json TEXT NOT NULL DEFAULT '[]',
    styles_json TEXT NOT NULL DEFAULT '[]',
    moods_json TEXT NOT NULL DEFAULT '[]',
    copyright TEXT,
    phonographic_copyright TEXT,
    notes TEXT,
    album_artist_display TEXT,
    revision INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(album_id) REFERENCES albums(id) ON DELETE CASCADE
);

CREATE TABLE album_credits (
    id INTEGER PRIMARY KEY,
    album_id INTEGER NOT NULL,
    artist_id INTEGER,
    display_name TEXT NOT NULL,
    role TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(album_id) REFERENCES albums(id) ON DELETE CASCADE,
    FOREIGN KEY(artist_id) REFERENCES artists(id) ON DELETE SET NULL
);

CREATE INDEX idx_album_credits_album_role
ON album_credits(album_id, role, position);

CREATE TABLE album_manual_merges (
    source_album_id INTEGER PRIMARY KEY,
    target_album_id INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY(source_album_id) REFERENCES albums(id) ON DELETE CASCADE,
    FOREIGN KEY(target_album_id) REFERENCES albums(id) ON DELETE CASCADE,
    CHECK(source_album_id <> target_album_id)
);

DROP VIEW album_identity_members;

CREATE VIEW album_identity_members AS
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
), automatic AS (
    SELECT
        album_id,
        identity_key,
        MIN(album_id) OVER (PARTITION BY identity_key) AS canonical_album_id
    FROM keyed
)
SELECT
    automatic.album_id,
    automatic.identity_key,
    COALESCE(manual.target_album_id, automatic.canonical_album_id) AS canonical_album_id
FROM automatic
LEFT JOIN album_manual_merges manual
  ON manual.source_album_id = automatic.album_id;
