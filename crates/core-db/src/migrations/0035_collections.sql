-- Test-release replacement: no legacy rule interpreter or dual playlist model.
DROP TRIGGER protect_system_playlist_delete;
DROP TRIGGER protect_system_playlist_identity;
DROP TRIGGER protect_system_playlist_items;
DROP TRIGGER protect_system_playlist_item_move;
DROP TABLE system_playlist_refresh_receipts;
DROP TABLE system_playlist_state;
DROP TABLE system_playlist_result_items;
DROP TABLE system_playlist_results;
DROP TABLE system_playlist_rule_history;
DROP TABLE system_playlist_settings;
DROP TABLE playlist_items;
DROP TABLE playlists;
UPDATE playback_queues SET source_json=NULL;

CREATE TABLE collections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    system_key TEXT UNIQUE,
    entity_type TEXT NOT NULL CHECK(entity_type IN ('track','album','artist','genre')),
    definition_json TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,
    result_version TEXT,
    error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE TABLE collection_results (
    version TEXT PRIMARY KEY,
    collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
    definition_json TEXT NOT NULL,
    revision INTEGER NOT NULL,
    generated_at TEXT NOT NULL,
    next_refresh_at TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    seed TEXT NOT NULL,
    matched_total INTEGER NOT NULL,
    result_total INTEGER NOT NULL,
    missing_json TEXT NOT NULL
);
CREATE INDEX collection_result_age ON collection_results(generated_at);
CREATE TABLE collection_result_items (
    version TEXT NOT NULL REFERENCES collection_results(version) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    entity_id INTEGER NOT NULL,
    item_json TEXT NOT NULL,
    track_ids_json TEXT NOT NULL,
    PRIMARY KEY(version, position), UNIQUE(version, entity_id)
);
CREATE TABLE collection_history (
    collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
    revision INTEGER NOT NULL, definition_json TEXT NOT NULL, saved_at TEXT NOT NULL,
    PRIMARY KEY(collection_id, revision)
);
CREATE TABLE collection_refresh_receipts (
    collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
    request_id TEXT NOT NULL, request_json TEXT NOT NULL,
    result_version TEXT NOT NULL REFERENCES collection_results(version) ON DELETE CASCADE,
    PRIMARY KEY(collection_id, request_id)
);
CREATE TABLE collection_play_plans (
    id TEXT PRIMARY KEY, source_json TEXT NOT NULL, tracks_json TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE TABLE collection_settings (
    id INTEGER PRIMARY KEY CHECK(id=1), management_enabled INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 1
);
INSERT INTO collection_settings(id) VALUES(1);
CREATE TABLE home_layout (
    id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL DEFAULT 1, sections_json TEXT NOT NULL
);
CREATE TRIGGER protect_collection_delete BEFORE DELETE ON collections WHEN OLD.system_key IS NOT NULL
BEGIN SELECT RAISE(ABORT, 'collection_protected'); END;
CREATE TRIGGER protect_collection_identity BEFORE UPDATE OF system_key, entity_type ON collections
WHEN NEW.system_key IS NOT OLD.system_key OR NEW.entity_type != OLD.entity_type
BEGIN SELECT RAISE(ABORT, 'collection_identity_immutable'); END;
INSERT INTO client_sync_changes(scope,reason,created_at) VALUES('collections','unified collections',datetime('now'));
UPDATE core_sync_state SET catalog_epoch=lower(hex(randomblob(16)));
