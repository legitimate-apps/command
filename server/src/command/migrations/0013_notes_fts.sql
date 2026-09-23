-- 0013_notes_fts.sql — lean full-text discovery over note bodies.
-- External-content FTS keeps the canonical body in `notes`; triggers synchronize every write.

CREATE VIRTUAL TABLE notes_fts USING fts5(
    body,
    content='notes',
    content_rowid='id'
);

CREATE TRIGGER notes_fts_insert AFTER INSERT ON notes BEGIN
    INSERT INTO notes_fts(rowid, body) VALUES (new.id, new.body);
END;

CREATE TRIGGER notes_fts_delete AFTER DELETE ON notes BEGIN
    INSERT INTO notes_fts(notes_fts, rowid, body) VALUES ('delete', old.id, old.body);
END;

CREATE TRIGGER notes_fts_update AFTER UPDATE OF body ON notes BEGIN
    INSERT INTO notes_fts(notes_fts, rowid, body) VALUES ('delete', old.id, old.body);
    INSERT INTO notes_fts(rowid, body) VALUES (new.id, new.body);
END;

INSERT INTO notes_fts(notes_fts) VALUES ('rebuild');
