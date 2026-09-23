"""The model tiers a user can force, and the slug each one runs.

Light on purpose (settings only): the app asks for this list without loading the agent.
The app names every tier from its slug, so when a self-hosted server overrides a model the
picker still shows what will actually answer.
"""

from __future__ import annotations

from ...config import get_settings

# Older ids for a tier, still accepted from clients that predate a rename.
_ALIASES = {"claude": "sonnet", "qwen": "fast", "terra": "gpt", "sol": "gpt"}


def model_tiers() -> list[tuple[str, str]]:
    """(tier id, configured slug) in the order the app lists them."""
    s = get_settings()
    return [
        ("opus", s.agent_model_opus),
        ("sonnet", s.agent_model_claude),
        ("fast", s.agent_model_fast),
        ("glm", s.agent_model_glm),
        ("kimi", s.agent_model_kimi),
        ("gpt", s.agent_model_gpt),
        ("luna", s.agent_model_gpt_luna),
    ]


def slug_for(choice: str | None) -> str | None:
    """The slug a forced tier runs; None for "auto" or an unknown id (the router decides)."""
    key = (choice or "auto").strip().lower()
    return dict(model_tiers()).get(_ALIASES.get(key, key))


def text_only_slugs() -> frozenset[str]:
    """Configured slugs that cannot accept image parts (`agent_text_only_models`)."""
    raw = get_settings().agent_text_only_models
    return frozenset(part.strip() for part in raw.split(",") if part.strip())
