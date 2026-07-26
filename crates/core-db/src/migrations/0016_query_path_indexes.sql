-- Reverse lookup indexes for the library views. The original composite
-- primary keys start with album_id/track_id, while artist pages filter from
-- artist_id and otherwise require full join-table scans.
CREATE INDEX IF NOT EXISTS idx_track_artists_artist_track
    ON track_artists(artist_id, track_id);

CREATE INDEX IF NOT EXISTS idx_album_artists_artist_album
    ON album_artists(artist_id, album_id);

-- Track details and distribution both resolve the ready replicas for a media
-- variant, with the preferred copy first.
CREATE INDEX IF NOT EXISTS idx_media_replicas_variant_state_primary
    ON media_replicas(media_variant_id, availability_state, is_primary DESC);

-- Client manifest reconciliation repeatedly finds active files in one root.
CREATE INDEX IF NOT EXISTS idx_files_root_availability
    ON files(library_root_id, availability_state, deleted_at);
