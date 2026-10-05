-- Display choices belong to library metadata, never to music-file tags.
CREATE TABLE track_display_preferences (
    track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
    mode TEXT NOT NULL CHECK(mode IN ('inherit', 'merged', 'independent')),
    updated_at TEXT NOT NULL
);
CREATE VIEW track_display_modes AS
SELECT t.id AS track_id,
       COALESCE((SELECT p.mode FROM track_display_preferences p
         WHERE p.track_id IN (SELECT t.id UNION ALL SELECT member.track_id
           FROM track_catalog_links member WHERE
           COALESCE(member.release_identity_id, member.release_track_id) =
           COALESCE(link.release_identity_id, link.release_track_id))
         ORDER BY p.updated_at DESC, p.track_id DESC LIMIT 1), 'inherit') AS mode
FROM tracks t LEFT JOIN track_catalog_links link ON link.track_id = t.id;
INSERT INTO client_sync_changes (scope, reason, created_at)
VALUES ('library', 'song display preferences', datetime('now'));

CREATE TABLE genre_split_settings (id INTEGER PRIMARY KEY CHECK(id = 1), separators_json TEXT NOT NULL);
INSERT INTO genre_split_settings VALUES (1, '[",", ";", "；", "、"]');
