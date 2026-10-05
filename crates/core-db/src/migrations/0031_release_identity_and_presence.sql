-- Scans describe inventory; only a live renderer heartbeat grants reachability.
ALTER TABLE devices ADD COLUMN online_until TEXT;
-- An album's track identity is independent of a user association between recordings.
ALTER TABLE track_catalog_links ADD COLUMN release_identity_id INTEGER;
UPDATE track_catalog_links SET release_identity_id = release_track_id;
CREATE INDEX idx_catalog_release_identity ON track_catalog_links(COALESCE(release_identity_id, release_track_id));
DROP VIEW visible_catalog_tracks;
CREATE VIEW visible_catalog_tracks AS
SELECT MIN(active.track_id) AS track_id, MIN(song.recording_id) AS recording_id
FROM active_catalog_tracks active
JOIN track_catalog_links link ON link.track_id = active.track_id
JOIN release_tracks song ON song.id = link.release_track_id
GROUP BY COALESCE(link.release_identity_id, link.release_track_id)
UNION ALL
SELECT active.track_id, NULL AS recording_id
FROM active_catalog_tracks active
WHERE NOT EXISTS (SELECT 1 FROM track_catalog_links link WHERE link.track_id = active.track_id);
INSERT INTO client_sync_changes (scope, reason, created_at)
VALUES ('library', 'separate release identities and live device presence', datetime('now'));

UPDATE core_sync_state SET catalog_epoch = lower(hex(randomblob(16)));
