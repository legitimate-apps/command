"""Minimal OpenAI-compatible chat client.

One sync httpx call against any OpenAI-compatible endpoint (OpenRouter, DashScope,
the Anthropic-compatible shim, …) chosen purely by base_url + key + model in
Settings. This is the seed the agentic backend grows from; for now it serves one
job — short note titles. Every failure returns None; callers must tolerate it.
"""

from __future__ import annotations

import httpx

from ...config import get_settings


def enabled() -> bool:
    """True when an API key is configured. Title-gen no-ops gracefully otherwise."""
    return bool(get_settings().ai_api_key)


def complete(
    messages: list[dict[str, str]],
    *,
    model: str | None = None,
    max_tokens: int = 256,
    temperature: float = 0.3,
    extra: dict[str, object] | None = None,
) -> str | None:
    """One chat completion → assistant text, or None on any failure (no key,
    network error, non-2xx, malformed body). `extra` merges into the request body
    (e.g. {"reasoning": {"enabled": False}} to skip a reasoning model's think pass)."""
    settings = get_settings()
    key = settings.ai_api_key
    if not key:
        return None
    headers = {
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "X-Title": "Command",  # OpenRouter ranking label (harmless elsewhere)
    }
    payload: dict[str, object] = {
        "model": model or settings.ai_title_model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
    }
    # Refuse upstream providers that may train on prompts (note bodies travel here).
    dc = settings.ai_provider_data_collection.strip().lower()
    if dc in {"deny", "allow"}:
        payload["provider"] = {"data_collection": dc}
    if extra:
        payload.update(extra)
    try:
        resp = httpx.post(
            f"{settings.ai_base_url.rstrip('/')}/chat/completions",
            headers=headers,
            json=payload,
            timeout=settings.ai_request_timeout,
        )
        resp.raise_for_status()
        content = resp.json()["choices"][0]["message"]["content"]
        return str(content).strip() or None
    except Exception:
        return None
