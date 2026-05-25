CREATE TABLE IF NOT EXISTS zone_aliases (
    zone_id TEXT PRIMARY KEY,
    alias TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
