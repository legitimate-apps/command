"""Upgrade a populated pre-0027 SQLite backup, never a production database."""
from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from command import db
from command.core import accounts, notes


def test_migration_0027_preserves_populated_database_copy(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    legacy_migrations = tmp_path / "legacy-migrations"
    legacy_migrations.mkdir()
    for migration in db.MIGRATIONS_DIR.glob("*.sql"):
        if migration.name < "0027":
            shutil.copyfile(migration, legacy_migrations / migration.name)
    source = str(tmp_path / "legacy.db")
    with monkeypatch.context() as patch:
        patch.setattr(db, "MIGRATIONS_DIR", legacy_migrations)
        db.init_db(source)
    ts = "2026-06-16T12:00:00+00:00"
    with db.connection(source) as conn:
        for username in ("one", "two"):
            account = accounts.register(conn, username, "password1")
            for index in range(30):
                cur = conn.execute(
                    "INSERT INTO notes (account_id, body, title, title_status, source, engine, locale, "
                    "hidden, archived_at, processed_at, created_at, updated_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (account.id, f"Legacy capture {index}: café", f"Title {index}", "user", "voice",
                     "speechtranscriber", "en-US", index % 2, ts if index % 3 == 0 else None,
                     ts if index % 4 == 0 else None, ts, ts),
                )
                conn.execute(
                    "INSERT INTO note_revisions (note_id, account_id, title, body, created_at) "
                    "VALUES (?, ?, ?, ?, ?)",
                    (cur.lastrowid, account.id, "Earlier", "Earlier capture", ts),
                )
            assignment = conn.execute(
                "INSERT INTO assignments (account_id, title, schedule_kind, rrule, scheduled_start, "
                "timezone, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (account.id, "Daily review", "routine", "FREQ=DAILY", ts, "America/New_York",
                 "scheduled", ts, ts),
            )
            conn.execute(
                "INSERT INTO activities (account_id, title, assignment_id, occurred_at, created_at, "
                "updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                (account.id, "Review completed", assignment.lastrowid, ts, ts, ts),
            )
        tables = [row[0] for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' "
            "AND name NOT LIKE 'notes_fts%' AND name != 'schema_migrations' ORDER BY name"
        )]
        baseline = {table: [tuple(row) for row in conn.execute(f"SELECT * FROM {table}")]
                    for table in tables}
    upgraded = str(tmp_path / "upgrade-copy.db")
    with db.connection(source) as original, db.connection(upgraded) as copy:
        original.backup(copy)
    db.init_db(upgraded)
    db.init_db(upgraded)  # startup retry must not re-apply ALTER TABLE
    with db.connection(upgraded) as conn:
        for table, before in baseline.items():
            width = len(before[0]) if before else 0
            after = [tuple(row)[:width] for row in conn.execute(f"SELECT * FROM {table}")]
            assert after == before, table
        assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        assert conn.execute("PRAGMA foreign_key_check").fetchall() == []
        assert conn.execute("SELECT COUNT(*) FROM notes_fts WHERE notes_fts MATCH 'café'").fetchone()[0] == 60
        for table in ("notes", "activities", "assignments"):
            keyed = conn.execute(
                f"SELECT COUNT(*) FROM {table} WHERE idempotency_key IS NOT NULL"
            ).fetchone()[0]
            assert keyed == 0
        note = notes.create(conn, 1, "after upgrade", idempotency_key="new-key")
        assert notes.create(conn, 1, "replay", idempotency_key="new-key").id == note.id
    with db.connection(source) as conn:
        assert conn.execute("SELECT COUNT(*) FROM notes").fetchone()[0] == 60
        assert "idempotency_key" not in {row[1] for row in conn.execute("PRAGMA table_info(notes)")}
