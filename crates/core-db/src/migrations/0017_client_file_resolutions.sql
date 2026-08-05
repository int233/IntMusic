CREATE TABLE IF NOT EXISTS client_file_resolutions (
    file_id INTEGER PRIMARY KEY,
    resolution_kind TEXT NOT NULL,
    target_track_id INTEGER,
    metadata_json TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(file_id) REFERENCES files(id) ON DELETE CASCADE,
    FOREIGN KEY(target_track_id) REFERENCES tracks(id) ON DELETE SET NULL,
    CHECK(resolution_kind IN ('matched_track', 'manual_metadata', 'ignored'))
);

CREATE INDEX IF NOT EXISTS idx_client_file_resolutions_target_track
    ON client_file_resolutions(target_track_id)
    WHERE target_track_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_files_attention
    ON files(scan_status, library_root_id)
    WHERE deleted_at IS NULL;

-- Earlier builds filled these fields with guesses even when the source file did
-- not contain authoritative identity metadata. Preserve explicit Live/Acoustic/
-- Demo values, but remove the two unconditional fallbacks.
UPDATE catalog_recordings
SET recording_kind = 'unknown'
WHERE recording_kind = 'studio';

UPDATE audio_masters
SET label = NULL
WHERE label = 'Library source';
