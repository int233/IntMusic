ALTER TABLE playback_queue_items ADD COLUMN stable_item_id TEXT;
ALTER TABLE playback_queue_items ADD COLUMN added_by_device_id TEXT;

CREATE UNIQUE INDEX idx_playback_queue_items_stable_item
ON playback_queue_items(stable_item_id)
WHERE stable_item_id IS NOT NULL;

CREATE TABLE playback_sessions_v3 (
    zone_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL UNIQUE,
    owner_device_id TEXT NOT NULL,
    epoch INTEGER NOT NULL DEFAULT 1,
    revision INTEGER NOT NULL DEFAULT 0,
    event_cursor INTEGER NOT NULL DEFAULT 0,
    repeat_mode TEXT NOT NULL DEFAULT 'off',
    shuffle INTEGER NOT NULL DEFAULT 0,
    stop_after_current INTEGER NOT NULL DEFAULT 0,
    last_command_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX idx_playback_sessions_v3_updated
ON playback_sessions_v3(updated_at);
