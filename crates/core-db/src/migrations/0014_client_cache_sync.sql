-- Durable identity and cursor used by offline-first Clients.  The journal is
-- intentionally compact: a change invalidates one logical scope and Clients
-- fetch a new normalized snapshot in the background.

CREATE TABLE IF NOT EXISTS core_sync_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    server_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

INSERT OR IGNORE INTO core_sync_state (id, server_id, created_at, updated_at)
VALUES (1, NULL, datetime('now'), datetime('now'));

CREATE TABLE IF NOT EXISTS client_sync_changes (
    cursor INTEGER PRIMARY KEY AUTOINCREMENT,
    scope TEXT NOT NULL,
    reason TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_client_sync_changes_scope_cursor
ON client_sync_changes(scope, cursor);

INSERT INTO client_sync_changes (scope, reason, created_at)
SELECT 'library', 'offline cache synchronization initialized', datetime('now')
WHERE NOT EXISTS (SELECT 1 FROM client_sync_changes);
