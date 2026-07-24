-- Prepared content may differ from the catalog source when Core transcodes a
-- distribution item. Keep source identity and delivery content separate.

ALTER TABLE distribution_items ADD COLUMN content_file_path TEXT;
ALTER TABLE distribution_items ADD COLUMN transcode_attempt_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE distribution_items ADD COLUMN transcode_claimed_at TEXT;
ALTER TABLE distribution_items ADD COLUMN transcode_lease_expires_at TEXT;

CREATE INDEX IF NOT EXISTS idx_distribution_items_transcode_lease
    ON distribution_items(state, transcode_lease_expires_at);
