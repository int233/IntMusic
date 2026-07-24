-- Separate catalog identity from physical files without breaking the v1 `tracks`
-- table. Existing `tracks` remain the compatibility-facing release track rows;
-- this graph provides the durable model used for editions, encodings, and copies.

CREATE TABLE IF NOT EXISTS catalog_works (
    id INTEGER PRIMARY KEY,
    global_id TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL,
    normalized_title TEXT NOT NULL,
    disambiguation TEXT,
    musicbrainz_work_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_catalog_works_musicbrainz
    ON catalog_works(musicbrainz_work_id)
    WHERE musicbrainz_work_id IS NOT NULL AND musicbrainz_work_id <> '';

CREATE TABLE IF NOT EXISTS catalog_recordings (
    id INTEGER PRIMARY KEY,
    global_id TEXT NOT NULL UNIQUE,
    work_id INTEGER,
    title TEXT NOT NULL,
    version_title TEXT,
    recording_kind TEXT NOT NULL DEFAULT 'studio',
    duration_ms INTEGER,
    isrc TEXT,
    musicbrainz_recording_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(work_id) REFERENCES catalog_works(id) ON DELETE SET NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_catalog_recordings_musicbrainz
    ON catalog_recordings(musicbrainz_recording_id)
    WHERE musicbrainz_recording_id IS NOT NULL
      AND musicbrainz_recording_id <> '';
CREATE INDEX IF NOT EXISTS idx_catalog_recordings_work
    ON catalog_recordings(work_id);

-- `albums` currently represent concrete library releases. This table gives each
-- one a stable release identity while leaving all current album APIs intact.
CREATE TABLE IF NOT EXISTS release_editions (
    id INTEGER PRIMARY KEY,
    global_id TEXT NOT NULL UNIQUE,
    album_id INTEGER UNIQUE,
    edition_title TEXT,
    edition_kind TEXT NOT NULL DEFAULT 'album',
    catalog_number TEXT,
    barcode TEXT,
    musicbrainz_release_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(album_id) REFERENCES albums(id) ON DELETE SET NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_release_editions_musicbrainz
    ON release_editions(musicbrainz_release_id)
    WHERE musicbrainz_release_id IS NOT NULL
      AND musicbrainz_release_id <> '';

-- A release track is the slot in a particular release. It is deliberately not a
-- file: several encodings/copies can satisfy one slot, and the same recording can
-- appear in several release tracks without removing it from any album.
CREATE TABLE IF NOT EXISTS release_tracks (
    id INTEGER PRIMARY KEY,
    global_id TEXT NOT NULL UNIQUE,
    release_id INTEGER,
    recording_id INTEGER NOT NULL,
    title TEXT NOT NULL,
    disc_number INTEGER,
    track_number INTEGER,
    duration_ms INTEGER,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(release_id) REFERENCES release_editions(id) ON DELETE SET NULL,
    FOREIGN KEY(recording_id) REFERENCES catalog_recordings(id)
);

CREATE INDEX IF NOT EXISTS idx_release_tracks_release_position
    ON release_tracks(release_id, disc_number, track_number);
CREATE INDEX IF NOT EXISTS idx_release_tracks_recording
    ON release_tracks(recording_id);

-- Maps the v1 file-backed track to its normalized release-track identity. More
-- than one legacy row may later map to the same release track after a confirmed
-- reconciliation; no automatic title-based merge is performed.
CREATE TABLE IF NOT EXISTS legacy_track_catalog_links (
    track_id INTEGER PRIMARY KEY,
    release_track_id INTEGER NOT NULL,
    match_kind TEXT NOT NULL DEFAULT 'seeded',
    match_confidence REAL NOT NULL DEFAULT 1.0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
    FOREIGN KEY(release_track_id) REFERENCES release_tracks(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_legacy_track_links_release_track
    ON legacy_track_catalog_links(release_track_id);

CREATE TABLE IF NOT EXISTS audio_masters (
    id INTEGER PRIMARY KEY,
    global_id TEXT NOT NULL UNIQUE,
    recording_id INTEGER NOT NULL,
    label TEXT,
    mastering_kind TEXT NOT NULL DEFAULT 'unknown',
    release_year INTEGER,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(recording_id) REFERENCES catalog_recordings(id)
);

CREATE INDEX IF NOT EXISTS idx_audio_masters_recording
    ON audio_masters(recording_id);

CREATE TABLE IF NOT EXISTS media_variants (
    id INTEGER PRIMARY KEY,
    global_id TEXT NOT NULL UNIQUE,
    audio_master_id INTEGER NOT NULL,
    variant_key TEXT NOT NULL UNIQUE,
    codec TEXT,
    container TEXT,
    bitrate INTEGER,
    sample_rate INTEGER,
    bit_depth INTEGER,
    channels INTEGER,
    duration_ms INTEGER,
    content_hash TEXT,
    quick_hash TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(audio_master_id) REFERENCES audio_masters(id)
);

CREATE INDEX IF NOT EXISTS idx_media_variants_master
    ON media_variants(audio_master_id);
CREATE INDEX IF NOT EXISTS idx_media_variants_content_hash
    ON media_variants(content_hash)
    WHERE content_hash IS NOT NULL AND content_hash <> '';

CREATE TABLE IF NOT EXISTS release_track_media_variants (
    release_track_id INTEGER NOT NULL,
    media_variant_id INTEGER NOT NULL,
    relation_kind TEXT NOT NULL DEFAULT 'exact',
    is_preferred INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    PRIMARY KEY(release_track_id, media_variant_id),
    FOREIGN KEY(release_track_id) REFERENCES release_tracks(id) ON DELETE CASCADE,
    FOREIGN KEY(media_variant_id) REFERENCES media_variants(id) ON DELETE CASCADE
);

-- A replica is one physical copy. `device_id` is NULL for files owned by the
-- Core; client manifests will use their paired device ID.
CREATE TABLE IF NOT EXISTS media_replicas (
    id INTEGER PRIMARY KEY,
    media_variant_id INTEGER NOT NULL,
    file_id INTEGER UNIQUE,
    device_id TEXT,
    library_root_id INTEGER,
    source_kind TEXT NOT NULL DEFAULT 'core',
    availability_state TEXT NOT NULL DEFAULT 'ready',
    is_primary INTEGER NOT NULL DEFAULT 0,
    last_verified_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(media_variant_id) REFERENCES media_variants(id) ON DELETE CASCADE,
    FOREIGN KEY(file_id) REFERENCES files(id) ON DELETE SET NULL,
    FOREIGN KEY(device_id) REFERENCES devices(id) ON DELETE SET NULL,
    FOREIGN KEY(library_root_id) REFERENCES library_roots(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_media_replicas_variant
    ON media_replicas(media_variant_id);
CREATE INDEX IF NOT EXISTS idx_media_replicas_device_state
    ON media_replicas(device_id, availability_state);

-- Safe compatibility bootstrap: every existing file starts as its own work,
-- recording, release track, master, variant, and replica. Explicit reconciliation
-- can link equivalent rows later; migration never guesses from title alone.
INSERT OR IGNORE INTO catalog_works (
    id, global_id, title, normalized_title, created_at, updated_at
)
SELECT
    t.id,
    lower(hex(randomblob(16))),
    t.title,
    lower(trim(t.title)),
    t.created_at,
    t.updated_at
FROM tracks t;

INSERT OR IGNORE INTO catalog_recordings (
    id, global_id, work_id, title, version_title, recording_kind,
    duration_ms, created_at, updated_at
)
SELECT
    t.id,
    lower(hex(randomblob(16))),
    t.id,
    t.title,
    t.subtitle,
    CASE
        WHEN lower(COALESCE(t.subtitle, '')) LIKE '%live%' THEN 'live'
        ELSE 'studio'
    END,
    t.duration_ms,
    t.created_at,
    t.updated_at
FROM tracks t;

INSERT OR IGNORE INTO release_editions (
    id, global_id, album_id, edition_title, edition_kind, created_at, updated_at
)
SELECT
    al.id,
    lower(hex(randomblob(16))),
    al.id,
    al.title,
    'album',
    al.created_at,
    al.updated_at
FROM albums al;

INSERT OR IGNORE INTO release_tracks (
    id, global_id, release_id, recording_id, title, disc_number,
    track_number, duration_ms, created_at, updated_at
)
SELECT
    t.id,
    lower(hex(randomblob(16))),
    t.album_id,
    t.id,
    t.title,
    t.disc_number,
    t.track_number,
    t.duration_ms,
    t.created_at,
    t.updated_at
FROM tracks t;

INSERT OR IGNORE INTO legacy_track_catalog_links (
    track_id, release_track_id, match_kind, match_confidence, created_at, updated_at
)
SELECT t.id, t.id, 'seeded', 1.0, t.created_at, t.updated_at
FROM tracks t;

INSERT OR IGNORE INTO audio_masters (
    id, global_id, recording_id, label, mastering_kind, release_year,
    created_at, updated_at
)
SELECT
    t.id,
    lower(hex(randomblob(16))),
    t.id,
    COALESCE(NULLIF(t.subtitle, ''), 'Library source'),
    CASE
        WHEN lower(COALESCE(t.subtitle, '')) LIKE '%remaster%' THEN 'remaster'
        ELSE 'unknown'
    END,
    t.year,
    t.created_at,
    t.updated_at
FROM tracks t;

INSERT OR IGNORE INTO media_variants (
    id, global_id, audio_master_id, variant_key, codec, container,
    bitrate, sample_rate, bit_depth, channels, duration_ms,
    content_hash, quick_hash, created_at, updated_at
)
SELECT
    t.id,
    lower(hex(randomblob(16))),
    t.id,
    'file:' || f.id,
    f.codec,
    f.extension,
    f.bitrate,
    f.sample_rate,
    f.bit_depth,
    f.channels,
    COALESCE(f.duration_ms, t.duration_ms),
    f.content_hash,
    f.quick_hash,
    f.created_at,
    f.updated_at
FROM tracks t
JOIN files f ON f.id = t.file_id;

INSERT OR IGNORE INTO release_track_media_variants (
    release_track_id, media_variant_id, relation_kind, is_preferred, created_at
)
SELECT t.id, t.id, 'exact', 1, t.created_at
FROM tracks t;

INSERT OR IGNORE INTO media_replicas (
    id, media_variant_id, file_id, device_id, library_root_id, source_kind,
    availability_state, is_primary, last_verified_at, created_at, updated_at
)
SELECT
    f.id,
    t.id,
    f.id,
    NULL,
    f.library_root_id,
    'core',
    CASE
        WHEN f.deleted_at IS NOT NULL THEN 'missing'
        WHEN f.scan_status = 'ok' THEN 'ready'
        ELSE 'unavailable'
    END,
    1,
    f.updated_at,
    f.created_at,
    f.updated_at
FROM tracks t
JOIN files f ON f.id = t.file_id;
