-- Use one visible track identity for lists, details, searches and device bindings.
-- A retired source must not hide a song that still has an active device copy.
CREATE VIEW visible_catalog_tracks AS
SELECT MIN(active.track_id) AS track_id, song.recording_id
FROM active_catalog_tracks active
JOIN track_catalog_links link ON link.track_id = active.track_id
JOIN release_tracks song ON song.id = link.release_track_id
GROUP BY song.recording_id
UNION ALL
SELECT active.track_id, NULL AS recording_id
FROM active_catalog_tracks active
WHERE NOT EXISTS (SELECT 1 FROM track_catalog_links link WHERE link.track_id = active.track_id);
INSERT INTO client_sync_changes (scope, reason, created_at)
VALUES ('library', 'unified visible catalog identities', datetime('now'));
