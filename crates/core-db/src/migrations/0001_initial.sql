CREATE TABLE IF NOT EXISTS library_roots (
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL UNIQUE,
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY,
    library_root_id INTEGER NOT NULL,
    path TEXT NOT NULL UNIQUE,
    relative_path TEXT NOT NULL,
    extension TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    modified_at TEXT NOT NULL,
    quick_hash TEXT,
    content_hash TEXT,
    scan_status TEXT NOT NULL,
    scan_message TEXT,
    codec TEXT,
    sample_rate INTEGER,
    channels INTEGER,
    duration_ms INTEGER,
    bitrate INTEGER,
    bit_depth INTEGER,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    FOREIGN KEY(library_root_id) REFERENCES library_roots(id)
);

CREATE TABLE IF NOT EXISTS artists (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    sort_name TEXT,
    normalized_name TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS albums (
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL,
    sort_title TEXT,
    normalized_title TEXT NOT NULL,
    album_key TEXT NOT NULL UNIQUE,
    album_artist_display TEXT,
    date TEXT,
    year INTEGER,
    original_date TEXT,
    total_discs INTEGER,
    cover_asset_id INTEGER,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS album_artists (
    album_id INTEGER NOT NULL,
    artist_id INTEGER NOT NULL,
    position INTEGER NOT NULL,
    PRIMARY KEY(album_id, artist_id),
    FOREIGN KEY(album_id) REFERENCES albums(id) ON DELETE CASCADE,
    FOREIGN KEY(artist_id) REFERENCES artists(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS tracks (
    id INTEGER PRIMARY KEY,
    file_id INTEGER NOT NULL UNIQUE,
    album_id INTEGER,
    title TEXT NOT NULL,
    sort_title TEXT,
    subtitle TEXT,
    disc_number INTEGER,
    disc_total INTEGER,
    track_number INTEGER,
    track_total INTEGER,
    duration_ms INTEGER,
    date TEXT,
    year INTEGER,
    bpm INTEGER,
    comment TEXT,
    cover_asset_id INTEGER,
    lyrics_id INTEGER,
    replaygain_track_gain REAL,
    replaygain_album_gain REAL,
    replaygain_track_peak REAL,
    replaygain_album_peak REAL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(file_id) REFERENCES files(id) ON DELETE CASCADE,
    FOREIGN KEY(album_id) REFERENCES albums(id)
);

CREATE TABLE IF NOT EXISTS track_artists (
    track_id INTEGER NOT NULL,
    artist_id INTEGER NOT NULL,
    role TEXT NOT NULL DEFAULT 'primary',
    position INTEGER NOT NULL,
    PRIMARY KEY(track_id, artist_id, role),
    FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
    FOREIGN KEY(artist_id) REFERENCES artists(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS genres (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    normalized_name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS track_genres (
    track_id INTEGER NOT NULL,
    genre_id INTEGER NOT NULL,
    PRIMARY KEY(track_id, genre_id),
    FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
    FOREIGN KEY(genre_id) REFERENCES genres(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS lyrics (
    id INTEGER PRIMARY KEY,
    track_id INTEGER NOT NULL UNIQUE,
    kind TEXT NOT NULL,
    text TEXT NOT NULL,
    parsed_json TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS assets (
    id INTEGER PRIMARY KEY,
    kind TEXT NOT NULL,
    source_file_id INTEGER,
    sha256 TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    width INTEGER,
    height INTEGER,
    original_path TEXT NOT NULL,
    thumb_256_path TEXT,
    thumb_512_path TEXT,
    created_at TEXT NOT NULL,
    UNIQUE(kind, sha256)
);

CREATE TABLE IF NOT EXISTS zones (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    output_id TEXT,
    state TEXT NOT NULL,
    volume REAL NOT NULL DEFAULT 1.0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS queue_items (
    id INTEGER PRIMARY KEY,
    zone_id TEXT NOT NULL,
    position INTEGER NOT NULL,
    track_id INTEGER NOT NULL,
    added_at TEXT NOT NULL,
    snapshot_title TEXT NOT NULL,
    snapshot_artist TEXT,
    snapshot_album TEXT,
    FOREIGN KEY(zone_id) REFERENCES zones(id) ON DELETE CASCADE,
    FOREIGN KEY(track_id) REFERENCES tracks(id)
);

CREATE TABLE IF NOT EXISTS playlists (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS playlist_items (
    id INTEGER PRIMARY KEY,
    playlist_id INTEGER NOT NULL,
    position INTEGER NOT NULL,
    track_id INTEGER NOT NULL,
    FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
    FOREIGN KEY(track_id) REFERENCES tracks(id)
);

CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
    track_id UNINDEXED,
    title,
    album,
    artist,
    genre,
    lyrics
);

CREATE TABLE IF NOT EXISTS search_cjk_grams (
    gram TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id INTEGER NOT NULL,
    weight INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY(gram, entity_type, entity_id)
);

CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    platform TEXT,
    token_hash TEXT NOT NULL,
    created_at TEXT NOT NULL,
    last_seen_at TEXT,
    revoked_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_files_library_root_id ON files(library_root_id);
CREATE INDEX IF NOT EXISTS idx_files_scan_status ON files(scan_status);
CREATE INDEX IF NOT EXISTS idx_tracks_album_id ON tracks(album_id);
CREATE INDEX IF NOT EXISTS idx_tracks_title ON tracks(title);
CREATE INDEX IF NOT EXISTS idx_albums_title ON albums(title);
CREATE INDEX IF NOT EXISTS idx_artists_name ON artists(name);

INSERT OR IGNORE INTO zones (id, name, state, volume, created_at, updated_at)
VALUES ('local', 'Local Output', 'stopped', 1.0, datetime('now'), datetime('now'));
