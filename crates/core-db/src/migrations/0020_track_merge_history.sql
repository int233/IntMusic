-- Confirmed physical-file reconciliation is intentionally non-destructive.
-- Legacy track rows remain available to old queues, playlists, and history while
-- their catalog links can point at one canonical release track. The snapshot
-- below makes every merge auditable and reversible.

CREATE TABLE IF NOT EXISTS track_merge_history (
    id TEXT PRIMARY KEY,
    target_track_id INTEGER NOT NULL,
    target_release_track_id INTEGER NOT NULL,
    source_track_ids_json TEXT NOT NULL,
    previous_links_json TEXT NOT NULL,
    inserted_relations_json TEXT NOT NULL,
    previous_master_recordings_json TEXT NOT NULL,
    previous_resolutions_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    undone_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_track_merge_history_target
    ON track_merge_history(target_track_id, created_at DESC);

CREATE TABLE IF NOT EXISTS track_merge_members (
    track_id INTEGER PRIMARY KEY,
    canonical_track_id INTEGER NOT NULL,
    merge_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
    FOREIGN KEY(canonical_track_id) REFERENCES tracks(id) ON DELETE CASCADE,
    FOREIGN KEY(merge_id) REFERENCES track_merge_history(id) ON DELETE CASCADE,
    CHECK(track_id <> canonical_track_id)
);

CREATE INDEX IF NOT EXISTS idx_track_merge_members_canonical
    ON track_merge_members(canonical_track_id);
