-- Core-coordinated delivery of Core-owned media to a Client library root.
-- Jobs and items are durable so a Client can resume after either side restarts.

CREATE TABLE IF NOT EXISTS distribution_jobs (
    id TEXT PRIMARY KEY,
    target_device_id TEXT NOT NULL,
    target_root_external_id TEXT NOT NULL,
    quality TEXT NOT NULL DEFAULT 'original',
    state TEXT NOT NULL DEFAULT 'queued',
    total_items INTEGER NOT NULL DEFAULT 0,
    completed_items INTEGER NOT NULL DEFAULT 0,
    failed_items INTEGER NOT NULL DEFAULT 0,
    total_bytes INTEGER NOT NULL DEFAULT 0,
    transferred_bytes INTEGER NOT NULL DEFAULT 0,
    error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    completed_at TEXT,
    FOREIGN KEY(target_device_id) REFERENCES devices(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_distribution_jobs_target_state
    ON distribution_jobs(target_device_id, state, created_at);

CREATE TABLE IF NOT EXISTS distribution_items (
    id TEXT PRIMARY KEY,
    job_id TEXT NOT NULL,
    track_id INTEGER NOT NULL,
    media_variant_id INTEGER NOT NULL,
    source_file_id INTEGER NOT NULL,
    relative_path TEXT NOT NULL,
    extension TEXT NOT NULL,
    expected_size_bytes INTEGER NOT NULL,
    expected_quick_hash TEXT,
    state TEXT NOT NULL DEFAULT 'queued',
    attempt_count INTEGER NOT NULL DEFAULT 0,
    transferred_bytes INTEGER NOT NULL DEFAULT 0,
    claimed_at TEXT,
    lease_expires_at TEXT,
    error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    completed_at TEXT,
    FOREIGN KEY(job_id) REFERENCES distribution_jobs(id) ON DELETE CASCADE,
    FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
    FOREIGN KEY(media_variant_id) REFERENCES media_variants(id) ON DELETE CASCADE,
    FOREIGN KEY(source_file_id) REFERENCES files(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_distribution_items_job_state
    ON distribution_items(job_id, state, created_at);
CREATE INDEX IF NOT EXISTS idx_distribution_items_lease
    ON distribution_items(state, lease_expires_at);
