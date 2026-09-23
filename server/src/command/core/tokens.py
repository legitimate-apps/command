"""Memorable MCP access tokens.

Format: ``cmd_<word>-<word>-<word>-<word>-<NNNN>`` e.g.
``cmd_otter-maple-harbor-quilt-7421``. Words come from the EFF Short Wordlist
(1295 entries); the 4-digit suffix adds entropy and keeps identical word-tuples
distinct. The default 4 words is ~55 bits — impractical to brute-force online
even without throttling, while staying short and memorable. (Login, the weaker
credential path, additionally has a per-username attempt limiter — see
``core/ratelimit.py``.) Existing 3-word tokens remain valid.

The ``cmd_`` prefix makes the token identifiable (GitHub-style) and easy to grep
as a secret to redact from logs.
"""

from __future__ import annotations

import math
import re
import secrets

from ._wordlist import WORDLIST

TOKEN_PREFIX = "cmd_"

# The word count every caller should mint at, and the default for every function here.
#
# `config.token_words` is the real knob and already says 4; the defaults in this module and in
# `accounts` still said 3 (~44 bits) from before that hardening. Every production path passes
# the setting explicitly, so no weak token was ever minted — but a future call site that forgot
# to thread it would have silently dropped 11 bits, with nothing to notice. The safe value is
# the default now, so forgetting costs nothing.
DEFAULT_WORDS = 4

# cmd_ + at least two hyphen-joined lowercase words + a 4-digit group.
_FORMAT = re.compile(r"^cmd_[a-z]+(?:-[a-z]+)+-\d{4}$")


def generate(words: int = DEFAULT_WORDS) -> str:
    """Generate a fresh memorable token with `words` random words + a 4-digit group."""
    if words < 2:
        raise ValueError("token must have at least 2 words")
    parts = [secrets.choice(WORDLIST) for _ in range(words)]
    return f"{TOKEN_PREFIX}{'-'.join(parts)}-{secrets.randbelow(10000):04d}"


def is_well_formed(token: str) -> bool:
    """Cheap shape check before hitting the DB (rejects obviously-malformed bearers)."""
    return bool(_FORMAT.match(token))


def verify(provided: str, stored: str) -> bool:
    """Constant-time compare of a presented token against a stored one."""
    return bool(provided) and bool(stored) and secrets.compare_digest(provided, stored)


def entropy_bits(words: int = DEFAULT_WORDS) -> float:
    """Approximate entropy of a generated token, in bits."""
    return words * math.log2(len(WORDLIST)) + math.log2(10000)
