-- A Client may lose the HTTP response after Core has committed a manifest
-- batch. Stable batch IDs let retries remain idempotent without inflating scan
-- counters or publishing duplicate catalog revisions.

CREATE TABLE client_library_manifest_batches (
    device_id TEXT NOT NULL,
    root_external_id TEXT NOT NULL,
    scan_id TEXT NOT NULL,
    batch_id TEXT NOT NULL,
    accepted_files INTEGER NOT NULL DEFAULT 0,
    complete INTEGER NOT NULL DEFAULT 0,
    processed_at TEXT NOT NULL,
    PRIMARY KEY(device_id, root_external_id, scan_id, batch_id)
);

CREATE INDEX idx_client_manifest_batches_scan
ON client_library_manifest_batches(device_id, root_external_id, scan_id);
