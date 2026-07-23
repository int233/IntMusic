CREATE TABLE IF NOT EXISTS artist_profiles (
    artist_id INTEGER PRIMARY KEY,
    display_name TEXT,
    sort_name TEXT,
    musicbrainz_id TEXT,
    artist_type TEXT,
    country TEXT,
    begin_date TEXT,
    end_date TEXT,
    disambiguation TEXT,
    biography TEXT,
    aliases_json TEXT NOT NULL DEFAULT '[]',
    genres_json TEXT NOT NULL DEFAULT '[]',
    links_json TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(artist_id) REFERENCES artists(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_artist_profiles_musicbrainz_id
    ON artist_profiles(musicbrainz_id)
    WHERE musicbrainz_id IS NOT NULL AND musicbrainz_id <> '';

CREATE TABLE IF NOT EXISTS artist_assets (
    id INTEGER PRIMARY KEY,
    artist_id INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    original_filename TEXT NOT NULL,
    storage_path TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    width INTEGER NOT NULL,
    height INTEGER NOT NULL,
    byte_size INTEGER NOT NULL,
    photo_type TEXT NOT NULL DEFAULT 'other',
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    UNIQUE(artist_id, sha256),
    FOREIGN KEY(artist_id) REFERENCES artists(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_artist_assets_artist
    ON artist_assets(artist_id, deleted_at, sort_order, id);

CREATE TABLE IF NOT EXISTS artist_visuals (
    artist_id INTEGER NOT NULL,
    slot TEXT NOT NULL,
    asset_id INTEGER,
    template TEXT NOT NULL DEFAULT 'single',
    fit TEXT NOT NULL DEFAULT 'cover',
    focal_x REAL NOT NULL DEFAULT 0.5,
    focal_y REAL NOT NULL DEFAULT 0.5,
    blur REAL NOT NULL DEFAULT 0,
    brightness REAL NOT NULL DEFAULT 1,
    revision INTEGER NOT NULL DEFAULT 1,
    updated_at TEXT NOT NULL,
    PRIMARY KEY(artist_id, slot),
    FOREIGN KEY(artist_id) REFERENCES artists(id) ON DELETE CASCADE,
    FOREIGN KEY(asset_id) REFERENCES artist_assets(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS artist_visual_regions (
    artist_id INTEGER NOT NULL,
    slot TEXT NOT NULL,
    position INTEGER NOT NULL CHECK(position >= 0 AND position < 5),
    asset_id INTEGER NOT NULL,
    crop_x REAL NOT NULL CHECK(crop_x >= 0 AND crop_x <= 1),
    crop_y REAL NOT NULL CHECK(crop_y >= 0 AND crop_y <= 1),
    crop_width REAL NOT NULL CHECK(crop_width > 0 AND crop_width <= 1),
    crop_height REAL NOT NULL CHECK(crop_height > 0 AND crop_height <= 1),
    focal_x REAL NOT NULL DEFAULT 0.5,
    focal_y REAL NOT NULL DEFAULT 0.5,
    PRIMARY KEY(artist_id, slot, position),
    FOREIGN KEY(artist_id, slot)
        REFERENCES artist_visuals(artist_id, slot)
        ON DELETE CASCADE,
    FOREIGN KEY(asset_id) REFERENCES artist_assets(id) ON DELETE CASCADE
);
