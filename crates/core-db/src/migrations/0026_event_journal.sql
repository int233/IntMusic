CREATE TABLE core_event_journal (
    cursor INTEGER PRIMARY KEY,
    event_id TEXT NOT NULL UNIQUE,
    event_type TEXT NOT NULL,
    envelope_json TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE INDEX idx_core_event_journal_type_cursor
ON core_event_journal(event_type, cursor);
