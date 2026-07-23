CREATE TABLE IF NOT EXISTS playback_queues (
    zone_id TEXT PRIMARY KEY,
    revision INTEGER NOT NULL DEFAULT 0,
    mode TEXT NOT NULL DEFAULT 'sequential',
    current_index INTEGER,
    shuffle_seed INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS playback_queue_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    zone_id TEXT NOT NULL,
    position INTEGER NOT NULL,
    track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    added_at TEXT NOT NULL,
    UNIQUE(zone_id, position)
);

CREATE INDEX IF NOT EXISTS idx_playback_queue_items_zone_position
ON playback_queue_items(zone_id, position);

CREATE TABLE IF NOT EXISTS zone_preferences (
    zone_id TEXT PRIMARY KEY,
    volume REAL NOT NULL DEFAULT 1.0,
    muted INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
