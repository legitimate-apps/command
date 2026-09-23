-- Per-occurrence reschedule (spec 2026-07-19-later-bucket): dragging ONE occurrence of a
-- routine assignment to a new time, without touching the series. The occurrence's identity
-- stays the ORIGINAL expansion date key — the same key occurrence_status uses — so a moved
-- occurrence keeps its status/note and can be reset to the series time.
CREATE TABLE occurrence_overrides (
  assignment_id INTEGER NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
  occurrence_date TEXT NOT NULL,   -- original expansion date key ("YYYY-MM-DD")
  occurs_at TEXT NOT NULL,         -- the new ISO-8601 instant
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (assignment_id, occurrence_date)
);
