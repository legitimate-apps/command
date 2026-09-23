"""Sanitising the model's answer into a note title.

`_sanitize` is the only thing standing between raw model output and a title the user sees in
their notes list. Models emit reasoning blocks, quote their answers, prefix them with markdown,
ramble past the word limit, and get truncated mid-thought — and this project has already been
bitten by a model fabricating output. It was 27% covered.

`generate_title` is thin over the shared client, so these drive the sanitiser directly and stub
the client for the round trip. Everything is a pure-string property: no model is called.
"""

from __future__ import annotations

import pytest

from command.core.ai import titles


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("Grocery List", "Grocery List"),
        ('"Grocery List"', "Grocery List"),          # models love quoting themselves
        ("'Grocery List'", "Grocery List"),
        ("**Grocery List**", "Grocery List"),        # markdown stripped from BOTH ends
        ("## Grocery List", "Grocery List"),
        ("Grocery List.", "Grocery List"),           # trailing punctuation the prompt forbade
        ("Grocery List:", "Grocery List"),
        ("  Grocery   List  ", "Grocery List"),      # collapsed whitespace
        ("Grocery List\nsome other rambling", "Grocery List"),   # only the first line
    ],
)
def test_it_reduces_model_flourish_to_a_bare_title(raw: str, expected: str) -> None:
    assert titles._sanitize(raw) == expected


def test_it_caps_the_title_at_three_words() -> None:
    """The prompt asks for 1-3 words; the model is not trusted to obey it."""
    assert titles._sanitize("One Two Three Four Five") == "One Two Three"


def test_a_reasoning_block_is_removed() -> None:
    assert titles._sanitize("<think>Let me consider…</think>\nGrocery List") == "Grocery List"


def test_a_truncated_reasoning_block_does_not_leak_into_the_title() -> None:
    """`max_tokens=24` can cut a model off mid-think, so the closing tag may never arrive.

    Without the open-ended pattern the user's notes list would show the model thinking out loud.
    """
    assert titles._sanitize("<think>Hmm, the note is about groceries and") is None


def test_empty_and_whitespace_only_answers_yield_nothing(
) -> None:
    for raw in ("", "   ", "\n\n", "<think></think>"):
        assert titles._sanitize(raw) is None, f"{raw!r} should not become a title"


def test_an_over_long_single_word_is_truncated() -> None:
    out = titles._sanitize("A" * 200)
    assert out is not None and len(out) <= 48


def test_generate_title_returns_none_for_an_empty_body_without_calling_the_model(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """No body means nothing to title — and nothing should be sent to a third party."""
    calls: list[object] = []
    monkeypatch.setattr(titles.client, "complete", lambda *a, **k: calls.append(a) or "X")
    assert titles.generate_title("   ") is None
    assert calls == [], "an empty note must not reach the model at all"


def test_generate_title_tolerates_the_model_returning_nothing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Every failure path returns None; the note keeps its first-line fallback."""
    monkeypatch.setattr(titles.client, "complete", lambda *a, **k: None)
    assert titles.generate_title("buy milk and eggs") is None


def test_generate_title_sanitises_what_the_model_returns(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        titles.client, "complete", lambda *a, **k: '<think>hmm</think>\n"Grocery Run"'
    )
    assert titles.generate_title("milk, eggs, bread") == "Grocery Run"


def test_the_note_body_is_truncated_before_it_is_sent(monkeypatch: pytest.MonkeyPatch) -> None:
    """A huge note must not be shipped wholesale to a third-party model."""
    seen: dict[str, object] = {}

    def fake_complete(messages, **kwargs):
        seen["user"] = messages[1]["content"]
        return "Long Note"

    monkeypatch.setattr(titles.client, "complete", fake_complete)
    titles.generate_title("x" * 10_000)
    assert len(str(seen["user"])) < 2_500, "the body must be capped before leaving the server"
