"""Operator backups: a consistent snapshot of the whole server as one streamed tar.gz.

The archive holds an online SQLite backup (the backup API copies a transactionally consistent
image while the server keeps serving — WAL readers never block writers) and the attachments
directory. It is produced as a plain generator of compressed chunks: tar headers and file
bytes are written by hand and gzipped incrementally, so memory stays at a few hundred KB no
matter how large the attachments are, and nothing but the database snapshot touches disk.

Attachments are taken AFTER the database snapshot. A file uploaded in between is simply extra
(no row points at it); one deleted in between is skipped, and its row — which the live server
has also deleted by then — lists a file the restored server reports as missing. Neither
corrupts anything.

What it deliberately leaves out: `instance-secrets.json`. Sealed values (peer tokens, the
owner's model key) are encrypted with it; shipping the key inside the same archive would undo
that. An operator who wants restorable peer tokens and calendar links pins
COMMAND_PEER_TOKEN_KEY and COMMAND_CALENDAR_EXPORT_SECRET in env.
"""

from __future__ import annotations

import os
import shutil
import sqlite3
import tarfile
import tempfile
import zlib
from collections.abc import Generator, Iterator
from pathlib import Path

CHUNK = 64 * 1024
DB_NAME = "command.db"


def snapshot_database(db_path: str) -> Path:
    """Copy the live database into a fresh temp dir beside it; returns the snapshot's path.

    The temp dir lives on the data volume (not /tmp, which in a container may be a small
    overlay). The caller owns it and must remove it (`cleanup`)."""
    work = Path(tempfile.mkdtemp(prefix=".backup-", dir=Path(db_path).resolve().parent))
    dest = work / DB_NAME
    try:
        src = sqlite3.connect(db_path)
        dst = sqlite3.connect(dest)
        try:
            src.backup(dst)
            # The copied header still says WAL; make the snapshot one self-contained file.
            dst.execute("PRAGMA journal_mode=DELETE")
        finally:
            dst.close()
            src.close()
    except Exception:
        shutil.rmtree(work, ignore_errors=True)
        raise
    return dest


def cleanup(snapshot: Path) -> None:
    shutil.rmtree(snapshot.parent, ignore_errors=True)


def _attachment_files(root: Path) -> Iterator[tuple[Path, str]]:
    """(path, archive-relative name) for every stored attachment. Skips in-progress `.tmp`
    uploads and anything that is not a regular file."""
    if not root.is_dir():
        return
    for account_dir in sorted(root.iterdir()):
        if not account_dir.is_dir() or account_dir.name.startswith("."):
            continue
        for f in sorted(account_dir.iterdir()):
            if f.name.startswith(".") or not f.is_file():
                continue
            yield f, f"{account_dir.name}/{f.name}"


def _header(name: str, size: int, mtime: float) -> bytes:
    info = tarfile.TarInfo(name)
    info.size = size
    info.mtime = int(mtime)
    info.mode = 0o600
    return info.tobuf(format=tarfile.PAX_FORMAT)


def archive_chunks(snapshot: Path, attachments_root: Path, prefix: str) -> Generator[bytes]:
    """Yield the gzip-compressed tar archive in chunks of roughly CHUNK bytes."""
    gz = zlib.compressobj(6, zlib.DEFLATED, 31)  # wbits 31 = gzip container
    pending: list[bytes] = []
    pending_size = 0
    written = 0  # uncompressed tar bytes, for the final record padding

    def feed(data: bytes) -> bytes | None:
        nonlocal pending_size, written
        written += len(data)
        out = gz.compress(data)
        if out:
            pending.append(out)
            pending_size += len(out)
        if pending_size >= CHUNK:
            return flush_pending()
        return None

    def flush_pending() -> bytes:
        nonlocal pending_size
        blob = b"".join(pending)
        pending.clear()
        pending_size = 0
        return blob

    def add(path: Path, name: str) -> Iterator[bytes]:
        try:
            fh = path.open("rb")
        except FileNotFoundError:
            return  # deleted since it was listed
        with fh:
            st = os.fstat(fh.fileno())  # of the file we opened, even if since unlinked
            size = st.st_size
            out = feed(_header(name, size, st.st_mtime))
            if out:
                yield out
            remaining = size
            while remaining > 0:
                block = fh.read(min(CHUNK, remaining))
                if not block:  # truncated underneath us; keep the archive well-formed
                    block = b"\0" * min(CHUNK, remaining)
                remaining -= len(block)
                out = feed(block)
                if out:
                    yield out
            pad = (-size) % tarfile.BLOCKSIZE
            if pad:
                out = feed(b"\0" * pad)
                if out:
                    yield out

    yield from add(snapshot, f"{prefix}/{DB_NAME}")
    for path, rel in _attachment_files(attachments_root):
        yield from add(path, f"{prefix}/attachments/{rel}")

    # End of archive: two zero blocks, then pad to a whole record (what tarfile itself writes).
    out = feed(b"\0" * (2 * tarfile.BLOCKSIZE))
    if out:
        yield out
    out = feed(b"\0" * ((-written) % tarfile.RECORDSIZE))
    if out:
        yield out
    pending.append(gz.flush())
    yield flush_pending()
