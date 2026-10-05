-- The catalog link is a real identity relationship, never a legacy fallback.
ALTER TABLE legacy_track_catalog_links RENAME TO track_catalog_links;
ALTER TABLE track_catalog_links ADD COLUMN source_recording_id INTEGER REFERENCES catalog_recordings(id);
UPDATE track_catalog_links SET source_recording_id = (SELECT recording_id FROM release_tracks WHERE id = release_track_id);
UPDATE core_sync_state SET catalog_epoch = lower(hex(randomblob(16))), updated_at = datetime('now') WHERE id = 1;
-- Playback state is rebuilt; stale desired state is not evidence of audio output.
DELETE FROM playback_command_receipts;
DELETE FROM playback_sessions_v3;
INSERT INTO client_sync_changes (scope, reason, created_at)
VALUES ('library', 'canonical catalog identity and renderer lifecycle rebuilt', datetime('now'));
