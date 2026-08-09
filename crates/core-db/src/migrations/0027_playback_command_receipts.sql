CREATE TABLE playback_command_receipts (
    origin_client_id TEXT NOT NULL,
    intent_id TEXT NOT NULL,
    zone_id TEXT NOT NULL,
    action TEXT NOT NULL,
    response_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (origin_client_id, intent_id)
);

CREATE INDEX idx_playback_command_receipts_created
ON playback_command_receipts(created_at);
