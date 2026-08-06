-- Logical catalog IDs are scoped to a catalog epoch. A Client must discard
-- cached entity IDs when this value changes, then bind its stable physical
-- file identities (device, root external id, file external id) to the current
-- Core catalog again.
--
-- This migration intentionally preserves Core-owned user data: favorites,
-- playlists, history, metadata edits, artwork, and the current media catalog.
-- Only stale Client caches are hard-reset by the corresponding Client update.

ALTER TABLE core_sync_state
ADD COLUMN catalog_epoch TEXT;

UPDATE core_sync_state
SET catalog_epoch = lower(hex(randomblob(16))),
    updated_at = datetime('now')
WHERE id = 1;

INSERT INTO client_sync_changes (scope, reason, created_at)
VALUES ('library', 'catalog epoch initialized; client cache rebind required', datetime('now'));
