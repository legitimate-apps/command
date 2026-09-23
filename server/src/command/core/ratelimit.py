"""In-process failed-attempt rate limiting for auth surfaces.

The server is a single uvicorn worker (Hard Rule 3), so a plain in-memory sliding
window is sufficient — no Redis, no extra process. Each key (e.g. a username on the
login path) accumulates timestamps of *failed* attempts; once too many land inside
the window the key is locked out until they age out. A success clears the key.

Keyed by username rather than client IP on purpose: the server sits behind a
Cloudflare Tunnel, so every request's peer address is the tunnel's loopback — an
IP key would collapse all users into one bucket (a global lockout). Per-username
directly protects each account's password from online brute-force, which is the
threat this guards.
"""

from __future__ import annotations

import time
from collections import deque
from threading import Lock

# Keys tracked at once. Keys are caller-chosen (any username string), so without a bound a
# flood of distinct usernames grows the dict forever — memory on a box with a <100 MB budget.
DEFAULT_MAX_KEYS = 10_000


class SlidingWindowLimiter:
    def __init__(
        self, *, max_attempts: int, window_seconds: float, max_keys: int = DEFAULT_MAX_KEYS
    ) -> None:
        self._max = max(1, max_attempts)
        self._window = window_seconds
        self._max_keys = max(1, max_keys)
        self._hits: dict[str, deque[float]] = {}
        self._lock = Lock()

    def _make_room(self, now: float) -> None:
        """Called (locked) before tracking a NEW key at capacity: drop every key whose failures
        have all aged out, then — if a flood of live keys still fills the table — the oldest
        tracked keys (dicts keep insertion order). Evicting a live key only forgets a few recent
        failures for one name; an unbounded table is an outage."""
        for key in [k for k, dq in self._hits.items() if not dq or now - dq[-1] > self._window]:
            del self._hits[key]
        while len(self._hits) >= self._max_keys:
            del self._hits[next(iter(self._hits))]

    def __len__(self) -> int:
        with self._lock:
            return len(self._hits)

    def _prune(self, dq: deque[float], now: float) -> None:
        while dq and now - dq[0] > self._window:
            dq.popleft()

    def allowed(self, key: str) -> bool:
        """True if `key` may attempt again (fewer than max failures in the window)."""
        now = time.monotonic()
        with self._lock:
            dq = self._hits.get(key)
            if not dq:
                return True
            self._prune(dq, now)
            if not dq:
                self._hits.pop(key, None)
                return True
            return len(dq) < self._max

    def record_failure(self, key: str) -> None:
        now = time.monotonic()
        with self._lock:
            dq = self._hits.get(key)
            if dq is None:
                if len(self._hits) >= self._max_keys:
                    self._make_room(now)
                dq = self._hits[key] = deque()
            self._prune(dq, now)
            dq.append(now)
            # Bound each key too: only the last `max` failures decide `allowed`.
            while len(dq) > self._max:
                dq.popleft()

    def reset(self, key: str) -> None:
        """Clear a key's failure history (call on a successful auth)."""
        with self._lock:
            self._hits.pop(key, None)

    def clear(self) -> None:
        """Drop all tracked keys (test isolation)."""
        with self._lock:
            self._hits.clear()
