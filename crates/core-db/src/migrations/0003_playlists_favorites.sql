ALTER TABLE tracks ADD COLUMN tag_rating INTEGER;
ALTER TABLE tracks ADD COLUMN tag_rating_scale INTEGER;

CREATE TABLE IF NOT EXISTS user_track_state (
    track_id INTEGER PRIMARY KEY,
    is_favorite INTEGER NOT NULL DEFAULT 0,
    user_rating INTEGER,
    rating_source TEXT,
    favorite_updated_at TEXT,
    rating_updated_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE
);

ALTER TABLE playlists ADD COLUMN kind TEXT NOT NULL DEFAULT 'manual';
ALTER TABLE playlists ADD COLUMN description TEXT;
ALTER TABLE playlists ADD COLUMN rules_json TEXT;

CREATE INDEX IF NOT EXISTS idx_playlist_items_playlist_position
ON playlist_items(playlist_id, position);

CREATE INDEX IF NOT EXISTS idx_playlist_items_track_id
ON playlist_items(track_id);

CREATE INDEX IF NOT EXISTS idx_user_track_state_favorite
ON user_track_state(is_favorite);

CREATE INDEX IF NOT EXISTS idx_tracks_tag_rating
ON tracks(tag_rating, tag_rating_scale);
