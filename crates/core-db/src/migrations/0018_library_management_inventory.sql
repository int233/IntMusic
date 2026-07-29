-- Library management is a Core-owned inventory. Devices and roots remain
-- visible after a Client disappears so another Client can administer them.
ALTER TABLE devices ADD COLUMN retired_at TEXT;
ALTER TABLE library_roots ADD COLUMN retired_at TEXT;

CREATE TABLE IF NOT EXISTS library_file_issues (
    id INTEGER PRIMARY KEY,
    file_id INTEGER NOT NULL,
    issue_kind TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'open',
    message TEXT,
    details_json TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    resolved_at TEXT,
    FOREIGN KEY(file_id) REFERENCES files(id) ON DELETE CASCADE,
    UNIQUE(file_id, issue_kind)
);

CREATE INDEX IF NOT EXISTS idx_library_file_issues_state
    ON library_file_issues(state, issue_kind, file_id);

CREATE INDEX IF NOT EXISTS idx_devices_retired
    ON devices(retired_at, last_seen_at);

CREATE INDEX IF NOT EXISTS idx_library_roots_retired
    ON library_roots(retired_at, owner_device_id);

-- Persist the problems already represented by scan_status so they are not
-- dependent on a transient settings response.
INSERT OR IGNORE INTO library_file_issues (
    file_id, issue_kind, state, message, created_at, updated_at
)
SELECT
    id,
    CASE scan_status
        WHEN 'tag_parse_error' THEN 'tag_parse_error'
        ELSE 'missing_required_tags'
    END,
    'open',
    scan_message,
    updated_at,
    updated_at
FROM files
WHERE deleted_at IS NULL
  AND scan_status IN ('needs_attention', 'tag_parse_error');

-- Earlier Client builds could create catalog entries even when authoritative
-- embedded identity tags were unavailable. Do not infer replacements from the
-- path: expose every unresolved historical Client file for explicit review.
INSERT OR IGNORE INTO library_file_issues (
    file_id, issue_kind, state, message, created_at, updated_at
)
SELECT
    file.id,
    'legacy_unverified',
    'open',
    'This Client file was catalogued before embedded-tag verification was recorded.',
    file.updated_at,
    file.updated_at
FROM files file
JOIN library_roots root ON root.id = file.library_root_id
LEFT JOIN client_file_resolutions resolution ON resolution.file_id = file.id
WHERE root.root_kind = 'client'
  AND file.deleted_at IS NULL
  AND file.scan_status IN ('ok', 'identified')
  AND resolution.file_id IS NULL;

-- Also surface placeholder identities created by old imports. The placeholder
-- is only used to detect an issue; no metadata is derived from file paths.
INSERT OR IGNORE INTO library_file_issues (
    file_id, issue_kind, state, message, created_at, updated_at
)
SELECT DISTINCT
    track.file_id,
    'legacy_unverified',
    'open',
    'The catalog identity contains an unverified placeholder artist.',
    file.updated_at,
    file.updated_at
FROM tracks track
JOIN files file ON file.id = track.file_id
JOIN track_artists relation
  ON relation.track_id = track.id AND relation.role = 'primary'
JOIN artists artist ON artist.id = relation.artist_id
WHERE file.deleted_at IS NULL
  AND lower(trim(artist.name)) = 'unknown artist';
