"""iCalendar (RFC 5545) export for an account's calendar.

Turns the expanded occurrences from `assignments.calendar()` into a `VCALENDAR` an Apple
Calendar subscription can poll. Subscriptions are fetched by the calendar client with no
cookie, so the URL carries a stateless per-account token: an HMAC of the account id under a
server secret (`calendar_export_secret`). No secret configured ⇒ export is disabled (matching
the codebase's "optional secret → graceful no-op" convention). Hidden items never reach the
export — `calendar()` is called with `include_hidden=False`.
"""

from __future__ import annotations

import hashlib
import hmac
from collections.abc import Mapping
from datetime import UTC, datetime, timedelta

from .assignments import Assignment, Occurrence, occurrence_duration

_SIG_LEN = 24


# --- Stateless per-account token -------------------------------------------------

def calendar_token(account_id: int, secret: str) -> str:
    sig = hmac.new(secret.encode(), str(account_id).encode(), hashlib.sha256).hexdigest()[:_SIG_LEN]
    return f"{account_id}.{sig}"


def verify_calendar_token(token: str, secret: str) -> int | None:
    """Return the account id if the token's signature is valid, else None (constant-time)."""
    if "." not in token:
        return None
    raw_id, sig = token.rsplit(".", 1)
    try:
        account_id = int(raw_id)
    except ValueError:
        return None
    expected = hmac.new(secret.encode(), raw_id.encode(), hashlib.sha256).hexdigest()[:_SIG_LEN]
    if not hmac.compare_digest(sig, expected):
        return None
    return account_id


# --- VCALENDAR rendering ---------------------------------------------------------

def _ics_escape(text: str) -> str:
    # RFC 5545 §3.3.11: backslash, semicolon, comma, newline.
    return (
        text.replace("\\", "\\\\")
        .replace(";", "\\;")
        .replace(",", "\\,")
        .replace("\r\n", "\\n")
        .replace("\n", "\\n")
    )


def _fold(line: str) -> str:
    # RFC 5545 §3.1: fold lines longer than 75 octets, continuation starts with a space.
    if len(line.encode()) <= 75:
        return line
    out, chunk = [], ""
    for ch in line:
        if len((chunk + ch).encode()) > 75:
            out.append(chunk)
            chunk = " " + ch
        else:
            chunk += ch
    out.append(chunk)
    return "\r\n".join(out)


def _utc(value: str) -> datetime:
    dt = datetime.fromisoformat(value)
    return (dt.replace(tzinfo=UTC) if dt.tzinfo is None else dt).astimezone(UTC)


def build_ics(occurrences: list[Occurrence], *, calendar_name: str, now: datetime,
              parents: Mapping[int, Assignment] | None = None,
              default_minutes: int = 30) -> str:
    """Render occurrences as a VCALENDAR.

    `parents` supplies the real duration. Without it every event is `default_minutes` long,
    which is what this used to do unconditionally — a three-hour meeting subscribed as thirty
    minutes, and a four-day trip as four separate half-hour blocks. An `Occurrence` has no
    duration of its own, so the parent's `scheduled_start`/`scheduled_end` is the only source.
    It stays optional (and falls back to the old behaviour) so a caller with no connection to
    hand can still render something sane — a bare reminder genuinely has no duration and gets
    `default_minutes` either way.
    """
    parents = parents or {}
    stamp = now.astimezone(UTC).strftime("%Y%m%dT%H%M%SZ")
    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Legitimate LLC//Command//EN",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH",
        _fold("X-WR-CALNAME:" + _ics_escape(calendar_name)),
    ]
    # A multi-day event expands to one occurrence PER DAY. In a calendar that must be ONE
    # event spanning the whole range, not one block per day, so emit it once — on whichever
    # of its days survives the query window, since day 1 may have been clipped off the front.
    multiday_seen: set[int] = set()

    for o in occurrences:
        parent = parents.get(o.assignment_id)
        span_start = _utc(o.occurs_at)
        span_end = span_start + timedelta(minutes=default_minutes)

        if o.day_count and o.day_count > 1:
            if o.assignment_id in multiday_seen:
                continue
            multiday_seen.add(o.assignment_id)
            if parent and parent.scheduled_start and parent.scheduled_end:
                span_start = _utc(parent.scheduled_start)
                span_end = _utc(parent.scheduled_end)
        elif parent is not None:
            # `occurrence_duration`, not end - start: a ROUTINE's scheduled_end is the date the
            # recurrence stops, so "daily for a week" used to export as seven 7-day events. A
            # zero duration is a point-in-time reminder — it keeps the default block so it is
            # visible rather than a zero-length invisible event.
            duration = occurrence_duration(parent)
            if duration > timedelta(0):
                span_end = span_start + duration

        start = span_start.strftime("%Y%m%dT%H%M%SZ")
        end = span_end.strftime("%Y%m%dT%H%M%SZ")
        uid = f"{o.assignment_id}-{start}@command.legitimateapps.com"
        lines += [
            "BEGIN:VEVENT",
            _fold(f"UID:{uid}"),
            f"DTSTAMP:{stamp}",
            f"DTSTART:{start}",
            f"DTEND:{end}",
            _fold("SUMMARY:" + _ics_escape(o.title)),
            f"STATUS:{'CANCELLED' if o.status == 'cancelled' else 'CONFIRMED'}",
            "END:VEVENT",
        ]
    lines.append("END:VCALENDAR")
    return "\r\n".join(lines) + "\r\n"
