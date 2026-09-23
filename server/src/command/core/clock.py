"""Central wall-clock.

Real time by default. When the env var ``COMMAND_FAKE_NOW_FILE`` names a file
containing an ISO-8601 timestamp, ``now()`` returns that instant instead — the
file is re-read on every call (never cached), so a scenario driver can advance
the server's notion of "now" live by rewriting one line. This is the
server-side twin of the app-side ``sim-faketime --file`` mechanism, letting a
simulated user and the server they talk to share one scenario clock across a
2-month-to-2-year lifespan.

Env-gated and default-off: with the variable unset (production, normal dev),
this module is exactly ``datetime.now(tz)`` with zero behavioural change. It is
never wired into a shipped code path other than as this transparent passthrough,
so it is safe to leave in place.

Every ``datetime.now(UTC)`` in ``core`` / ``rest`` that governs behaviour
(reminders coming due, assignment lead-time, token/credit/subscription expiry,
confirm-token TTL, stored ``created_at``/``updated_at``) routes through here so a
single file write moves the whole server through time coherently.
"""

from __future__ import annotations

import os
from datetime import UTC, datetime, tzinfo
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

_ENV = "COMMAND_FAKE_NOW_FILE"


def _override() -> datetime | None:
    """The scenario instant from the timestamp file, or ``None`` when disabled.

    Tolerant by design: an unset var, a missing/empty/garbled file all fall back
    to real time rather than raising — a broken scenario clock must never take
    the server down. Accepts ``2027-03-15T10:00:00+00:00`` and the
    space-separated ``2027-03-15 10:00:00`` form; a naive value is read as UTC.
    """
    path = os.environ.get(_ENV)
    if not path:
        return None
    try:
        with open(path) as fh:
            raw = fh.read().strip()
    except OSError:
        return None
    if not raw:
        return None
    if "T" not in raw and " " in raw:
        raw = raw.replace(" ", "T", 1)
    try:
        dt = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt


def now(tz: tzinfo = UTC) -> datetime:
    """Current time in ``tz`` — real, or the scenario instant when faked."""
    dt = _override()
    if dt is None:
        return datetime.now(tz)
    return dt.astimezone(tz)


def zone_or_utc(name: str | None) -> ZoneInfo:
    """An account's ``ZoneInfo``, degrading to UTC for missing/unknown names.

    Shared rather than re-declared per module: "which day is it for this user" decides
    briefing windows and weekend detection, and two private copies had already appeared. A
    third would be the point at which they start disagreeing. (``assignments._zone`` stays
    separate on purpose — its ``None`` return distinguishes legacy rows that have no zone at
    all from rows that have one, which is a domain fact and not a fallback.)

    Never raises: an unknown zone must not 500 a read, and it must not take down the sweep
    that walks every account.
    """
    try:
        return ZoneInfo(name or "UTC")
    except (ZoneInfoNotFoundError, ValueError):
        return ZoneInfo("UTC")
