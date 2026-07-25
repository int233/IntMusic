ALTER TABLE zone_preferences
ADD COLUMN volume_mode TEXT NOT NULL DEFAULT 'player';

ALTER TABLE zone_preferences
ADD COLUMN player_volume REAL NOT NULL DEFAULT 1.0;

ALTER TABLE zone_preferences
ADD COLUMN player_muted INTEGER NOT NULL DEFAULT 0;

ALTER TABLE zone_preferences
ADD COLUMN system_volume REAL;

ALTER TABLE zone_preferences
ADD COLUMN system_muted INTEGER;

UPDATE zone_preferences
SET player_volume = volume,
    player_muted = muted;
