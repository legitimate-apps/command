"""Check a live Command database for corruption the application layer cannot see.

Static review found nothing on 2026-08-05; this set of queries, run against production, found
four foreign-key violations in the first thirty seconds — `settings` and `access_tokens` rows
belonging to an account that no longer existed. Code review could never have found them, because
the *code* was correct: they were residue from a delete performed on a connection where
`PRAGMA foreign_keys` was OFF. That is the gap this script exists to cover.

Run it after any manual database surgery, after restoring a backup, after a migration that moves
rows, and whenever something is behaving oddly in a way the logs don't explain.

    # on the host
    docker exec -i command python - < scripts/db_integrity_check.py
    # or locally against a copy
    COMMAND_DB_PATH=/path/to/command.db uv run python scripts/db_integrity_check.py

Read-only: opens the database with `mode=ro`, so it can be run against production safely and
cannot itself be the thing that breaks something. Exits non-zero if any check fails, so it can
gate a deploy or a restore.
"""

from __future__ import annotations

import sqlite3
import sys

Problem = tuple[str, str]


def _open() -> tuple[sqlite3.Connection, str]:
    from command.config import get_settings

    path = get_settings().db_path
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn, path


def _tables_with_account_id(conn: sqlite3.Connection) -> list[str]:
    out = []
    for row in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    ):
        table = row["name"]
        if any(c[1] == "account_id" for c in conn.execute(f"PRAGMA table_info({table})")):
            out.append(table)
    return out


def check_sqlite_level(conn: sqlite3.Connection) -> list[Problem]:
    """SQLite's own opinion first — cheap, and it catches what nothing else will."""
    problems: list[Problem] = []
    integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        problems.append(("integrity_check", integrity))
    for row in conn.execute("PRAGMA foreign_key_check"):
        problems.append(("foreign_key_check", f"{row[0]} rowid={row[1]} -> {row[2]}"))
    return problems


def check_orphans(conn: sqlite3.Connection) -> list[Problem]:
    """Rows belonging to an account that no longer exists.

    Enumerated from the schema rather than a hand-written list, so a table added later is
    covered without anyone remembering to add it here.
    """
    problems: list[Problem] = []
    for table in _tables_with_account_id(conn):
        n = conn.execute(
            f"SELECT COUNT(*) FROM {table} WHERE account_id NOT IN (SELECT id FROM accounts)"
        ).fetchone()[0]
        if n:
            problems.append(("orphaned rows", f"{table}: {n}"))
    return problems


def check_dangling_references(conn: sqlite3.Connection) -> list[Problem]:
    """Cross-entity references that point at something deleted.

    Not all of these are declared foreign keys, so `foreign_key_check` does not cover them.
    """
    checks = [
        ("sent_reminders -> assignment",
         "SELECT COUNT(*) FROM sent_reminders s "
         "WHERE NOT EXISTS (SELECT 1 FROM assignments a WHERE a.id = s.assignment_id)"),
        ("assignments -> goal",
         "SELECT COUNT(*) FROM assignments a WHERE a.goal_id IS NOT NULL "
         "AND NOT EXISTS (SELECT 1 FROM goals g WHERE g.id = a.goal_id)"),
        ("assignments -> assignee",
         "SELECT COUNT(*) FROM assignments a WHERE a.assignee_id IS NOT NULL "
         "AND NOT EXISTS (SELECT 1 FROM delegatees d WHERE d.id = a.assignee_id)"),
        ("activities -> actor",
         "SELECT COUNT(*) FROM activities x WHERE x.actor_id IS NOT NULL "
         "AND NOT EXISTS (SELECT 1 FROM delegatees d WHERE d.id = x.actor_id)"),
        ("note_revisions -> note",
         "SELECT COUNT(*) FROM note_revisions r "
         "WHERE NOT EXISTS (SELECT 1 FROM notes n WHERE n.id = r.note_id)"),
        ("task_items -> assignment",
         "SELECT COUNT(*) FROM task_items t WHERE t.parent_type = 'assignment' "
         "AND NOT EXISTS (SELECT 1 FROM assignments a WHERE a.id = t.parent_id)"),
        ("agent_messages -> thread",
         "SELECT COUNT(*) FROM agent_messages m "
         "WHERE NOT EXISTS (SELECT 1 FROM agent_threads t WHERE t.id = m.thread_id)"),
    ]
    problems: list[Problem] = []
    for label, sql in checks:
        n = conn.execute(sql).fetchone()[0]
        if n:
            problems.append(("dangling reference", f"{label}: {n}"))
    return problems


def check_domain_invariants(conn: sqlite3.Connection) -> list[Problem]:
    """States the domain says cannot happen. Any hit means a write path has a bug."""
    checks = [
        ("assignment status outside the valid set",
         "SELECT COUNT(*) FROM assignments WHERE status NOT IN "
         "('todo','scheduled','in_progress','done','blocked','cancelled','skipped')"),
        ("routine assignment with no rrule",
         "SELECT COUNT(*) FROM assignments WHERE schedule_kind = 'routine' "
         "AND (rrule IS NULL OR rrule = '')"),
        ("sporadic assignment carrying an rrule",
         "SELECT COUNT(*) FROM assignments WHERE schedule_kind = 'sporadic' "
         "AND rrule IS NOT NULL AND rrule <> ''"),
        ("assignment ending before it starts",
         "SELECT COUNT(*) FROM assignments WHERE scheduled_end IS NOT NULL "
         "AND scheduled_start IS NOT NULL AND scheduled_end < scheduled_start"),
        ("duplicate delegatee slug within an account",
         "SELECT COUNT(*) FROM (SELECT account_id, slug FROM delegatees "
         "GROUP BY account_id, slug HAVING COUNT(*) > 1)"),
        ("account with no self-delegatee",
         "SELECT COUNT(*) FROM accounts a WHERE NOT EXISTS "
         "(SELECT 1 FROM delegatees d WHERE d.account_id = a.id AND d.is_self = 1)"),
        # A negative balance means a debit path skipped its own guard — this is money.
        ("account with a negative credit balance",
         "SELECT COUNT(*) FROM (SELECT account_id FROM credit_ledger "
         "GROUP BY account_id HAVING SUM(delta) < 0)"),
        ("FTS index out of step with notes",
         "SELECT ABS((SELECT COUNT(*) FROM notes) - (SELECT COUNT(*) FROM notes_fts))"),
    ]
    problems: list[Problem] = []
    for label, sql in checks:
        n = conn.execute(sql).fetchone()[0]
        if n:
            problems.append(("invariant", f"{label}: {n}"))
    return problems


def check_attachment_files(conn: sqlite3.Connection) -> list[Problem]:
    """Attachment rows and their bytes must agree — in both directions.

    A row with no file breaks a download; a file with no row is a private document nothing
    will ever clean up, which matters because deletion is supposed to remove the bytes.
    """
    from command.core import attachments as attachments_core

    problems: list[Problem] = []
    root = attachments_core.storage_root()
    if not root.exists():
        rows = conn.execute("SELECT COUNT(*) FROM attachments").fetchone()[0]
        if rows:
            problems.append(("attachments", f"{rows} rows but no storage directory at {root}"))
        return problems

    on_disk = {
        (d.name, f.name)
        for d in root.iterdir() if d.is_dir()
        for f in d.iterdir() if not f.name.startswith(".")
    }
    for row in conn.execute("SELECT id, account_id, stored_name, size_bytes FROM attachments"):
        path = root / str(row["account_id"]) / row["stored_name"]
        if not path.is_file():
            problems.append(("attachments", f"id={row['id']}: row with no file"))
        elif path.stat().st_size != row["size_bytes"]:
            problems.append((
                "attachments",
                f"id={row['id']}: size {path.stat().st_size} != recorded {row['size_bytes']}",
            ))
        on_disk.discard((str(row["account_id"]), row["stored_name"]))
    for account, name in sorted(on_disk):
        problems.append(("attachments", f"file with no row: {account}/{name}"))
    return problems


CHECKS = (
    ("SQLite", check_sqlite_level),
    ("orphans", check_orphans),
    ("references", check_dangling_references),
    ("invariants", check_domain_invariants),
    ("attachments", check_attachment_files),
)


def main() -> int:
    conn, path = _open()
    print(f"database: {path}")
    problems: list[Problem] = []
    for name, check in CHECKS:
        found = check(conn)
        print(f"  {name:<12} {'OK' if not found else f'{len(found)} PROBLEM(S)'}")
        problems += found

    if not problems:
        print("\nAll checks passed.")
        return 0
    print(f"\n{len(problems)} problem(s):")
    for kind, detail in problems:
        print(f"  [{kind}] {detail}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
