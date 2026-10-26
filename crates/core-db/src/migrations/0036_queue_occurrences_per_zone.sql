-- A transferred queue keeps its occurrence IDs and shuffle order. An occurrence
-- is addressed together with its output, so it may exist on both outputs.
DROP INDEX idx_playback_queue_items_stable_item;
CREATE UNIQUE INDEX idx_playback_queue_items_stable_item
ON playback_queue_items(zone_id, stable_item_id)
WHERE stable_item_id IS NOT NULL;
