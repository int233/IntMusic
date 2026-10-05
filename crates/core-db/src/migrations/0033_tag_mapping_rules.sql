-- Only user-authored mappings are applied. Original metadata snapshots remain intact.
DROP TABLE genre_split_settings;
CREATE TABLE metadata_tag_settings (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    settings_json TEXT NOT NULL
);
INSERT INTO metadata_tag_settings VALUES
(1, '{"artist_separators":[",",";","；","、"],"genre_separators":[",",";","；","、"],"tag_mappings":[]}');
