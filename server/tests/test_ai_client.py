"""Shared OpenAI-compatible client — request-shape guarantees.

The one thing worth pinning here is the OpenRouter provider-routing block: note
bodies and agent turns are user data, so a misconfigured (or silently dropped)
`data_collection` preference is a privacy regression, not a cosmetic one.
"""

from __future__ import annotations

from typing import Any

import pytest


class _Resp:
    status_code = 200

    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict[str, Any]:
        return {"choices": [{"message": {"content": "ok"}}]}


def _capture(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """Stub httpx.post inside the client module and hand back the sent payload."""
    from command.core.ai import client

    seen: dict[str, Any] = {}

    def fake_post(url: str, **kwargs: Any) -> _Resp:
        seen["url"] = url
        seen["json"] = kwargs.get("json")
        return _Resp()

    monkeypatch.setattr(client.httpx, "post", fake_post)
    return seen


def test_completion_denies_prompt_training_providers_by_default(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from command.config import get_settings
    from command.core.ai import client

    get_settings.cache_clear()
    monkeypatch.setenv("COMMAND_AI_API_KEY", "test-key")
    seen = _capture(monkeypatch)

    assert client.complete([{"role": "user", "content": "hi"}]) == "ok"
    assert seen["json"]["provider"] == {"data_collection": "deny"}

    get_settings.cache_clear()


def test_data_collection_is_configurable_and_ignores_junk(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """`allow` widens the pool back to OpenRouter's default; an unrecognized value
    omits the block entirely rather than sending something the API will reject."""
    from command.config import get_settings
    from command.core.ai import client

    for value, expected in (("allow", {"data_collection": "allow"}), ("banana", None)):
        get_settings.cache_clear()
        monkeypatch.setenv("COMMAND_AI_API_KEY", "test-key")
        monkeypatch.setenv("COMMAND_AI_PROVIDER_DATA_COLLECTION", value)
        seen = _capture(monkeypatch)
        client.complete([{"role": "user", "content": "hi"}])
        assert seen["json"].get("provider") == expected

    get_settings.cache_clear()
