ALTER TABLE playlists ADD COLUMN system_key TEXT;
CREATE UNIQUE INDEX playlists_system_key ON playlists(system_key) WHERE system_key IS NOT NULL;
ALTER TABLE playlists ADD COLUMN rules_revision INTEGER NOT NULL DEFAULT 1;
ALTER TABLE playlists ADD COLUMN defaults_version INTEGER NOT NULL DEFAULT 1;

CREATE TABLE system_playlist_settings (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    management_enabled INTEGER NOT NULL DEFAULT 0,
    revision INTEGER NOT NULL DEFAULT 1
);
INSERT INTO system_playlist_settings (id) VALUES (1);

CREATE TABLE system_playlist_results (
    version TEXT PRIMARY KEY,
    system_key TEXT NOT NULL,
    rules_revision INTEGER NOT NULL,
    rules_json TEXT NOT NULL,
    seed TEXT NOT NULL,
    generated_at TEXT NOT NULL,
    next_refresh_at TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    matched_total INTEGER NOT NULL,
    result_total INTEGER NOT NULL
);
CREATE INDEX system_playlist_result_age ON system_playlist_results(generated_at);
CREATE TABLE system_playlist_result_items (
    version TEXT NOT NULL REFERENCES system_playlist_results(version) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    track_json TEXT NOT NULL,
    PRIMARY KEY(version, position)
);
CREATE TABLE system_playlist_state (
    system_key TEXT PRIMARY KEY,
    result_version TEXT REFERENCES system_playlist_results(version),
    error TEXT
);
CREATE TABLE system_playlist_rule_history (
    system_key TEXT NOT NULL,
    revision INTEGER NOT NULL,
    rules_json TEXT NOT NULL,
    saved_at TEXT NOT NULL,
    PRIMARY KEY(system_key, revision)
);
CREATE TABLE system_playlist_refresh_receipts (
    system_key TEXT NOT NULL,
    request_id TEXT NOT NULL,
    request_json TEXT NOT NULL,
    result_version TEXT NOT NULL REFERENCES system_playlist_results(version) ON DELETE CASCADE,
    PRIMARY KEY(system_key, request_id)
);

INSERT INTO playlists (name, kind, description, rules_json, system_key, created_at, updated_at)
VALUES ('今日随听', 'smart', '由 Core 每日生成的随听歌单', '{"match_mode":"all","filters":[],"limit":30,"only_available":false,"added_within_days":null,"max_per_artist":null,"max_per_album":null}', 'daily_mix', datetime('now'), datetime('now')),
       ('新近入库', 'smart', '最近加入资料库的歌曲', '{"match_mode":"all","filters":[],"limit":100,"only_available":false,"added_within_days":null,"max_per_artist":null,"max_per_album":null}', 'recently_added', datetime('now'), datetime('now'));
INSERT INTO system_playlist_state(system_key) SELECT system_key FROM playlists WHERE system_key IS NOT NULL;
INSERT INTO system_playlist_rule_history(system_key, revision, rules_json, saved_at)
SELECT system_key, rules_revision, rules_json, updated_at FROM playlists WHERE system_key IS NOT NULL;

-- Protection also applies to future code paths that bypass the API helpers.
CREATE TRIGGER protect_system_playlist_delete BEFORE DELETE ON playlists WHEN OLD.system_key IS NOT NULL
BEGIN SELECT RAISE(ABORT, 'system_playlist_protected'); END;
CREATE TRIGGER protect_system_playlist_identity BEFORE UPDATE OF system_key, name, kind ON playlists
WHEN OLD.system_key IS NOT NULL OR NEW.system_key IS NOT NULL
BEGIN SELECT RAISE(ABORT, 'system_playlist_protected'); END;
CREATE TRIGGER protect_system_playlist_items BEFORE INSERT ON playlist_items
WHEN EXISTS(SELECT 1 FROM playlists WHERE id=NEW.playlist_id AND system_key IS NOT NULL)
BEGIN SELECT RAISE(ABORT, 'system_playlist_protected'); END;
CREATE TRIGGER protect_system_playlist_item_move BEFORE UPDATE OF playlist_id ON playlist_items
WHEN EXISTS(SELECT 1 FROM playlists WHERE id=NEW.playlist_id AND system_key IS NOT NULL)
BEGIN SELECT RAISE(ABORT, 'system_playlist_protected'); END;

ALTER TABLE playback_queues ADD COLUMN source_json TEXT;
