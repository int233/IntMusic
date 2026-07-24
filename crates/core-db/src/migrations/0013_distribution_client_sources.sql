-- A selected track may exist only on a Client. The source Client uploads the
-- exact replica to Core's short-lived relay cache before optional transcoding
-- and normal destination delivery.

ALTER TABLE distribution_items ADD COLUMN source_device_id TEXT;
ALTER TABLE distribution_items ADD COLUMN source_root_external_id TEXT;
ALTER TABLE distribution_items ADD COLUMN source_relative_path TEXT;
ALTER TABLE distribution_items ADD COLUMN source_upload_attempt_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE distribution_items ADD COLUMN source_upload_claimed_at TEXT;
ALTER TABLE distribution_items ADD COLUMN source_upload_lease_expires_at TEXT;

CREATE INDEX IF NOT EXISTS idx_distribution_items_source_upload
    ON distribution_items(source_device_id, state, source_upload_lease_expires_at);
