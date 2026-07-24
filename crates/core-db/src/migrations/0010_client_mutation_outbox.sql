-- Idempotency receipts for changes created while a Client was disconnected.
-- The mutation payload remains Client-owned until Core confirms the receipt.

CREATE TABLE IF NOT EXISTS client_mutation_receipts (
    device_id TEXT NOT NULL,
    mutation_id TEXT NOT NULL,
    mutation_kind TEXT NOT NULL,
    occurred_at TEXT NOT NULL,
    applied_at TEXT NOT NULL,
    PRIMARY KEY(device_id, mutation_id),
    FOREIGN KEY(device_id) REFERENCES devices(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_client_mutation_receipts_applied
    ON client_mutation_receipts(applied_at);
