-- A retired source remains visible and can be restored. A removed source keeps
-- its audit rows but disappears from active source management until the same
-- Client identity registers it again.

ALTER TABLE library_roots ADD COLUMN removed_at TEXT;

CREATE INDEX IF NOT EXISTS idx_library_roots_removed
    ON library_roots(removed_at, owner_device_id, root_kind);
