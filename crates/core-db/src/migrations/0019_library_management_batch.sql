-- Removed Client devices disappear from normal management views while their
-- inventory rows remain as an audit trail. A later manifest from the same
-- device identity can restore the record safely.
ALTER TABLE devices ADD COLUMN removed_at TEXT;

CREATE INDEX IF NOT EXISTS idx_devices_removed
    ON devices(removed_at, retired_at, last_seen_at);

-- Inventory queries resolve catalog links and open issues by file. These
-- reverse-direction indexes prevent a full relationship scan per file.
CREATE INDEX IF NOT EXISTS idx_release_track_variants_variant
    ON release_track_media_variants(media_variant_id, release_track_id);

CREATE INDEX IF NOT EXISTS idx_library_file_issues_file_state
    ON library_file_issues(file_id, state, issue_kind);

CREATE INDEX IF NOT EXISTS idx_files_inventory_state
    ON files(library_root_id, deleted_at, availability_state, scan_status);
