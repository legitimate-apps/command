"""AI note titles — a 1-3 word title generated after the user closes a note.

Runs as a FastAPI background task off the note's close endpoint: read the note,
ask a cheap model for a terse title, write it back with provenance `ai` (or mark
`error`). Best-effort and self-contained — it opens its own DB connection and
never raises into the request path.
"""

from __future__ import annotations

import contextlib
import re
import time

from ...config import get_settings
from ...db import connection
from ...errors import NotFound
from .. import notes
from . import client

_TITLE_SYSTEM = (
    "You name notes. Reply with ONLY a 1-3 word title in Title Case. "
    "No punctuation, no quotes, no preamble, no trailing period."
)


def _sanitize(raw: str) -> str | None:
    # Drop reasoning blocks some models emit, even when truncated mid-think.
    cleaned = re.sub(r"(?is)<think>.*?</think>", " ", raw)
    cleaned = re.sub(r"(?is)<think>.*$", " ", cleaned)
    cleaned = cleaned.replace("</think>", " ").replace("<think>", " ")
    lines = [ln.strip() for ln in cleaned.splitlines() if ln.strip()]
    if not lines:
        return None
    line = re.sub(r"\s+", " ", lines[0].strip("\"'`*#").strip())
    words = [w for w in line.split(" ") if w]
    if not words:
        return None
    title = " ".join(words[:3]).strip(" .,:;-")
    return title[:48].strip() or None


def generate_title(body: str) -> str | None:
    """Ask the model for a terse title. None when AI is disabled or anything fails."""
    body = (body or "").strip()
    if not body:
        return None
    out = client.complete(
        [
            {"role": "system", "content": _TITLE_SYSTEM},
            {"role": "user", "content": f"Note:\n{body[:2000]}\n\nTitle:"},
        ],
        max_tokens=24,
        temperature=0.2,
        extra={"reasoning": {"enabled": False}},  # a title needs no think pass
    )
    return _sanitize(out) if out else None


def generate_and_save_title(note_id: int, account_id: int) -> None:
    """Background task: persist an AI title (or mark `error`). Runs after the response
    on its own connection; retries the first read so it works even if the note isn't
    committed yet (title-on-create), and owns the generating->ai/error flow."""
    db_path = get_settings().db_path
    body: str | None = None
    for _ in range(6):
        try:
            with connection(db_path) as conn:
                body = notes.mark_title_generating(conn, account_id, note_id).body
            break
        except NotFound:
            time.sleep(0.25)  # note not committed yet — retry briefly
        except Exception:
            return
    if body is None:
        return
    title = generate_title(body)
    with contextlib.suppress(Exception), connection(db_path) as conn:
        if title:
            notes.set_title(conn, account_id, note_id, title, status="ai")
        else:
            notes.mark_title_error(conn, account_id, note_id)
