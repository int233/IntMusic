CREATE TABLE IF NOT EXISTS playback_events (
    id INTEGER PRIMARY KEY,
    zone_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    track_id INTEGER,
    track_title TEXT,
    position_ms INTEGER,
    related_zone_id TEXT,
    reason TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY(track_id) REFERENCES tracks(id)
);

CREATE TABLE IF NOT EXISTS playback_sessions (
    id INTEGER PRIMARY KEY,
    zone_id TEXT NOT NULL,
    track_id INTEGER NOT NULL,
    track_title TEXT NOT NULL,
    started_at TEXT NOT NULL,
    start_position_ms INTEGER NOT NULL DEFAULT 0,
    ended_at TEXT,
    end_position_ms INTEGER,
    end_reason TEXT,
    played_ms INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(track_id) REFERENCES tracks(id)
);

CREATE INDEX IF NOT EXISTS idx_playback_events_created_at ON playback_events(created_at);
CREATE INDEX IF NOT EXISTS idx_playback_events_track_id ON playback_events(track_id);
CREATE INDEX IF NOT EXISTS idx_playback_events_zone_id ON playback_events(zone_id);
CREATE INDEX IF NOT EXISTS idx_playback_sessions_started_at ON playback_sessions(started_at);
CREATE INDEX IF NOT EXISTS idx_playback_sessions_track_id ON playback_sessions(track_id);
CREATE INDEX IF NOT EXISTS idx_playback_sessions_open ON playback_sessions(zone_id, ended_at);
