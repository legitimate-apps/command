from __future__ import annotations

import pytest

from command.core import tokens
from command.core._wordlist import WORDLIST


def test_format() -> None:
    t = tokens.generate(3)
    assert t.startswith("cmd_")
    assert tokens.is_well_formed(t)
    parts = t.removeprefix("cmd_").split("-")
    assert len(parts) == 4  # 3 words + 4-digit group
    assert parts[-1].isdigit() and len(parts[-1]) == 4
    assert all(w in WORDLIST for w in parts[:-1])


def test_effectively_unique() -> None:
    seen = {tokens.generate() for _ in range(2000)}
    assert len(seen) > 1990  # ~44 bits → collisions vanishingly rare


def test_verify_constant_time() -> None:
    t = tokens.generate()
    assert tokens.verify(t, t)
    assert not tokens.verify(t, t + "x")
    assert not tokens.verify("", t)
    assert not tokens.verify(t, "")


def test_entropy() -> None:
    assert tokens.entropy_bits(3) > 40


def test_requires_two_words() -> None:
    with pytest.raises(ValueError, match="at least 2 words"):
        tokens.generate(1)


def test_malformed_rejected() -> None:
    assert not tokens.is_well_formed("nope")
    assert not tokens.is_well_formed("cmd_only-1234")  # one word
    assert not tokens.is_well_formed("cmd_otter-maple-123")  # 3-digit group
    assert not tokens.is_well_formed("otter-maple-1234")  # no prefix
    assert tokens.is_well_formed("cmd_otter-maple-1234")  # two words is valid shape
