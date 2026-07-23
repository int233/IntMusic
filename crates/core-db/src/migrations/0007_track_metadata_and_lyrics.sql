CREATE TABLE IF NOT EXISTS track_metadata_sources (
    file_id INTEGER PRIMARY KEY,
    source_kind TEXT NOT NULL DEFAULT 'file',
    data_json TEXT NOT NULL,
    captured_at TEXT NOT NULL,
    FOREIGN KEY(file_id) REFERENCES files(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS track_metadata_overrides (
    track_id INTEGER NOT NULL,
    field_key TEXT NOT NULL,
    value_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY(track_id, field_key),
    FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS track_metadata_state (
    track_id INTEGER PRIMARY KEY,
    revision INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS track_metadata_revisions (
    id INTEGER PRIMARY KEY,
    track_id INTEGER NOT NULL,
    revision INTEGER NOT NULL,
    changes_json TEXT NOT NULL,
    client_label TEXT,
    created_at TEXT NOT NULL,
    UNIQUE(track_id, revision),
    FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_track_metadata_revisions_track
    ON track_metadata_revisions(track_id, revision DESC);

ALTER TABLE lyrics ADD COLUMN language TEXT;
ALTER TABLE lyrics ADD COLUMN translation_text TEXT;
ALTER TABLE lyrics ADD COLUMN pronunciation_text TEXT;
ALTER TABLE lyrics ADD COLUMN offset_ms INTEGER NOT NULL DEFAULT 0;
ALTER TABLE lyrics ADD COLUMN source TEXT NOT NULL DEFAULT 'file';
ALTER TABLE lyrics ADD COLUMN is_locked INTEGER NOT NULL DEFAULT 0;
ALTER TABLE lyrics ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
