-- Device-owned library roots are catalog sources, not paths that the Core can
-- walk. Shadow `files` rows keep the v1 file-backed catalog compatible while
-- `media_replicas` records the device that can actually read each copy.

ALTER TABLE library_roots ADD COLUMN root_kind TEXT NOT NULL DEFAULT 'core';
ALTER TABLE library_roots ADD COLUMN owner_device_id TEXT;
ALTER TABLE library_roots ADD COLUMN external_id TEXT;
ALTER TABLE library_roots ADD COLUMN display_name TEXT;
ALTER TABLE library_roots ADD COLUMN path_hint TEXT;
ALTER TABLE library_roots ADD COLUMN last_seen_at TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_library_roots_client_identity
    ON library_roots(root_kind, owner_device_id, external_id);
CREATE INDEX IF NOT EXISTS idx_library_roots_kind_enabled
    ON library_roots(root_kind, enabled);

ALTER TABLE files ADD COLUMN client_file_id TEXT;
ALTER TABLE files ADD COLUMN last_seen_scan_id TEXT;
ALTER TABLE files ADD COLUMN availability_state TEXT NOT NULL DEFAULT 'ready';

CREATE UNIQUE INDEX IF NOT EXISTS idx_files_client_identity
    ON files(library_root_id, client_file_id)
    WHERE client_file_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_files_client_scan
    ON files(library_root_id, last_seen_scan_id);

CREATE TABLE IF NOT EXISTS client_library_sync_state (
    device_id TEXT NOT NULL,
    root_external_id TEXT NOT NULL,
    scan_id TEXT NOT NULL,
    started_at TEXT NOT NULL,
    completed_at TEXT,
    accepted_files INTEGER NOT NULL DEFAULT 0,
    missing_files INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(device_id, root_external_id),
    FOREIGN KEY(device_id) REFERENCES devices(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_client_library_sync_scan
    ON client_library_sync_state(scan_id);
